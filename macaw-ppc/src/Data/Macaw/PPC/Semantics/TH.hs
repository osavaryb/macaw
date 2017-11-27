{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}

module Data.Macaw.PPC.Semantics.TH
  ( genExecInstruction
  ) where

import qualified Data.ByteString as BS
import qualified Data.Constraint as C

import           Control.Lens ( (^.) )
import           Data.Proxy ( Proxy(..) )
import qualified Data.List as L
import qualified Data.Text as T
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax
import           GHC.TypeLits
import           Text.Read ( readMaybe )

import           Data.Parameterized.Classes
import           Data.Parameterized.FreeParamF ( FreeParamF(..) )
import qualified Data.Parameterized.Lift as LF
import qualified Data.Parameterized.Map as Map
import qualified Data.Parameterized.NatRepr as NR
import qualified Data.Parameterized.Nonce as PN
import qualified Data.Parameterized.ShapedList as SL
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.TraversableFC as FC
import           Data.Parameterized.Witness ( Witness(..) )
import qualified Lang.Crucible.BaseTypes as CT
import qualified Lang.Crucible.Solver.Interface as SI
import qualified Lang.Crucible.Solver.SimpleBuilder as S
import qualified Lang.Crucible.Solver.SimpleBackend as S
import qualified Lang.Crucible.Solver.Symbol as Sy

import qualified Dismantle.PPC as D
import qualified Dismantle.Tablegen.TH.Capture as DT

import qualified SemMC.BoundVar as BV
import           SemMC.Formula
import qualified SemMC.Architecture as A
import qualified SemMC.Architecture.Location as L
import qualified SemMC.Architecture.PPC.Eval as PE
import qualified SemMC.Architecture.PPC.Location as APPC
import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.Memory as M
import qualified Data.Macaw.Types as M

import Data.Parameterized.NatRepr ( knownNat
                                  , natValue
                                  )

import           Data.Macaw.SemMC.Generator
import           Data.Macaw.SemMC.Translations
import           Data.Macaw.SemMC.TH.Monad

import           Data.Macaw.PPC.Arch
import           Data.Macaw.PPC.Operand
import           Data.Macaw.PPC.PPCReg

type Sym t = S.SimpleBackend t

-- | A different parameterized pair wrapper; the one in Data.Parameterized.Map
-- hides the @tp@ parameter under an existential, while we need the variant that
-- exposes it.
data PairF a b tp = PairF (a tp) (b tp)

-- | Generate the top-level lambda with a case expression over an instruction
-- (casing on opcode)
--
-- > \ipVar (Instruction opcode operandList) ->
-- >   case opcode of
-- >     ${CASES}
--
-- where each case in ${CASES} is defined by 'mkSemanticsCase'; each case
-- matches one opcode.
instructionMatcher :: (OrdF a, LF.LiftF a,
                       A.Architecture arch,
                       L.Location arch ~ APPC.Location arch,
                       1 <= APPC.ArchRegWidth arch,
                       M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
                   => (forall tp . L.Location arch tp -> Q Exp)
                   -> [MatchQ]
                   -> Map.MapF (Witness c a) (PairF (ParameterizedFormula (Sym t) arch) (DT.CaptureInfo c a))
                   -> Q Exp
instructionMatcher ltr specialCases formulas = do
  ipVarName <- newName "ipVal"
  opcodeVar <- newName "opcode"
  operandListVar <- newName "operands"
  let normalCases = map (mkSemanticsCase ltr ipVarName operandListVar) (Map.toList formulas)
  lamE [varP ipVarName, conP 'D.Instruction [varP opcodeVar, varP operandListVar]] (caseE (varE opcodeVar) (normalCases ++ specialCases))

-- | Generate a single case for one opcode of the case expression.
--
-- > ADD4 -> ${BODY}
--
-- where the ${BODY} is generated by 'mkOperandListCase'
mkSemanticsCase :: (LF.LiftF a,
                    A.Architecture arch,
                    L.Location arch ~ APPC.Location arch,
                    1 <= APPC.ArchRegWidth arch,
                    M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
                => (forall tp . L.Location arch tp -> Q Exp)
                -> Name
                -> Name
                -> Map.Pair (Witness c a) (PairF (ParameterizedFormula (Sym t) arch) (DT.CaptureInfo c a))
                -> MatchQ
mkSemanticsCase ltr ipVarName operandListVar (Map.Pair (Witness opc) (PairF semantics capInfo)) =
  match (conP (DT.capturedOpcodeName capInfo) []) (normalB (mkOperandListCase ltr ipVarName operandListVar opc semantics capInfo)) []

-- | For each opcode case, we have a sub-case expression to destructure the
-- operand list into names that we can reference.  This generates an expression
-- of the form:
--
-- > case operandList of
-- >   op1 :> op2 :> op3 :> Nil -> ${BODY}
--
-- where ${BODY} is generated by 'genCaseBody', which references the operand
-- names introduced by this case (e.g., op1, op2, op3).  Those names are pulled
-- from the DT.CaptureInfo, and have been pre-allocated.  See
-- Dismantle.Tablegen.TH.Capture.captureInfo for information on how those names
-- are generated.
--
-- Note that the structure of the operand list is actually a little more
-- complicated than the above.  Each operand actually has an additional level of
-- wrapper around it, and really looks like:
--
-- >    Dismantle.PPC.ADD4
-- >      -> case operands_ayaa of {
-- >           (Gprc gprc0 :> (Gprc gprc1 :> (Gprc gprc2 :> Nil)))
-- >             -> ${BODY}
--
-- in an example with three general purpose register operands.
mkOperandListCase :: (L.Location arch ~ APPC.Location arch,
                      A.Architecture arch,
                      1 <= APPC.ArchRegWidth arch,
                      M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
                  => (forall tp0 . L.Location arch tp0 -> Q Exp)
                  -> Name
                  -> Name
                  -> a tp
                  -> ParameterizedFormula (Sym t) arch tp
                  -> DT.CaptureInfo c a tp
                  -> Q Exp
mkOperandListCase ltr ipVarName operandListVar opc semantics capInfo = do
  body <- genCaseBody ltr ipVarName opc semantics (DT.capturedOperandNames capInfo)
  DT.genCase capInfo operandListVar body

data BoundVarInterpretations arch t =
  BoundVarInterpretations { locVars :: Map.MapF (SI.BoundVar (Sym t)) (L.Location arch)
                          , opVars  :: Map.MapF (SI.BoundVar (Sym t)) (FreeParamF Name)
                          , regsValName :: Name
                          }

-- | This is the function that translates formulas (semantics) into expressions
-- that construct macaw terms.
--
-- The stub implementation is essentially
--
-- > undefined ipVar arg1 arg2
--
-- to avoid unused variable warnings.
--
-- The two maps (locVars and opVars) are crucial for translating parameterized
-- formulas into expressions.
genCaseBody :: forall a sh t arch
               . (L.Location arch ~ APPC.Location arch,
                  A.Architecture arch,
                  1 <= APPC.ArchRegWidth arch,
                  M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
            => (forall tp . L.Location arch tp -> Q Exp)
            -> Name
            -> a sh
            -> ParameterizedFormula (Sym t) arch sh
            -> SL.ShapedList (FreeParamF Name) sh
            -> Q Exp
genCaseBody ltr ipVarName _opc semantics varNames = do
  regsName <- newName "_regs"
  translateFormula ltr ipVarName semantics (BoundVarInterpretations locVarsMap opVarsMap regsName) varNames
  where
    locVarsMap :: Map.MapF (SI.BoundVar (Sym t)) (L.Location arch)
    locVarsMap = Map.foldrWithKey (collectVarForLocation (Proxy @arch)) Map.empty (pfLiteralVars semantics)

    opVarsMap :: Map.MapF (SI.BoundVar (Sym t)) (FreeParamF Name)
    opVarsMap = SL.foldrFCIndexed (collectOperandVars varNames) Map.empty (pfOperandVars semantics)

collectVarForLocation :: forall tp arch proxy t
                       . proxy arch
                      -> L.Location arch tp
                      -> SI.BoundVar (Sym t) tp
                      -> Map.MapF (SI.BoundVar (Sym t)) (L.Location arch)
                      -> Map.MapF (SI.BoundVar (Sym t)) (L.Location arch)
collectVarForLocation _ loc bv = Map.insert bv loc

-- | Index variables that map to operands
--
-- We record the TH 'Name' for the 'SI.BoundVar' that stands in for each
-- operand.  The idea will be that we will look up bound variables in this map
-- to be able to compute a TH expression to refer to it.
--
-- We have to unwrap and rewrap the 'FreeParamF' because the type parameter
-- changes when we switch from 'BV.BoundVar' to 'SI.BoundVar'.  See the
-- SemMC.BoundVar module for information about the nature of that change
-- (basically, from 'Symbol' to BaseType).
collectOperandVars :: forall sh tp arch t
                    . SL.ShapedList (FreeParamF Name) sh
                   -> SL.Index sh tp
                   -> BV.BoundVar (Sym t) arch tp
                   -> Map.MapF (SI.BoundVar (Sym t)) (FreeParamF Name)
                   -> Map.MapF (SI.BoundVar (Sym t)) (FreeParamF Name)
collectOperandVars varNames ix (BV.BoundVar bv) m =
  case SL.indexShapedList varNames ix of
    FreeParamF name -> Map.insert bv (FreeParamF name) m

-- | Generate an implementation of 'execInstruction' that runs in the
-- 'PPCGenerator' monad.  We pass in both the original list of semantics files
-- along with the list of opcode info objects.  We can match them up using
-- equality on opcodes (via a MapF).  Generating a combined list up-front would
-- be ideal, but is difficult for various TH reasons (we can't call 'lift' on
-- all of the things we would need to for that).
--
-- The structure of the term produced is documented in 'instructionMatcher'
genExecInstruction :: (A.Architecture arch,
                       OrdF a,
                       ShowF a,
                       LF.LiftF a,
                       L.Location arch ~ APPC.Location arch,
                       1 <= APPC.ArchRegWidth arch,
                       M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
                   => proxy arch
                   -> (forall tp . L.Location arch tp -> Q Exp)
                   -> [MatchQ]
                   -- ^ Special cases to splice into the expression
                   -> (forall sh . c sh C.:- BuildOperandList arch sh)
                   -- ^ A constraint implication to let us extract/weaken the
                   -- constraint in our 'Witness' to the required 'BuildOperandList'
                   -> [(Some (Witness c a), BS.ByteString)]
                   -- ^ A list of opcodes (with constraint information
                   -- witnessed) paired with the bytestrings containing their
                   -- semantics.  This comes from semmc.
                   -> [Some (DT.CaptureInfo c a)]
                   -- ^ Extra information for each opcode to let us generate
                   -- some TH to match them.  This comes from the semantics
                   -- definitions in semmc.
                   -> Q Exp
genExecInstruction _ ltr specialCases impl semantics captureInfo = do
  Some ng <- runIO PN.newIONonceGenerator
  sym <- runIO (S.newSimpleBackend ng)
  formulas <- runIO (loadFormulas sym impl semantics)
  let formulasWithInfo = foldr (attachInfo formulas) Map.empty captureInfo
  instructionMatcher ltr specialCases formulasWithInfo
  where
    attachInfo m0 (Some ci) m =
      let co = DT.capturedOpcode ci
      in case Map.lookup co m0 of
        Nothing -> m
        Just pf -> Map.insert co (PairF pf ci) m

natReprTH :: M.NatRepr w -> Q Exp
natReprTH w = [| knownNat :: M.NatRepr $(litT (numTyLit (natValue w))) |]

natReprFromIntTH :: Int -> Q Exp
natReprFromIntTH i = [| knownNat :: M.NatRepr $(litT (numTyLit (fromIntegral i))) |]

-- | Sequence a list of monadic actions without constructing an intermediate
-- list structure
doSequenceQ :: [StmtQ] -> [Stmt] -> Q Exp
doSequenceQ stmts body = doE (stmts ++ map return body)

translateFormula :: forall arch t sh .
                    (L.Location arch ~ APPC.Location arch,
                     A.Architecture arch,
                     1 <= APPC.ArchRegWidth arch,
                     M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
                 => (forall tp . L.Location arch tp -> Q Exp)
                 -> Name
                 -> ParameterizedFormula (Sym t) arch sh
                 -> BoundVarInterpretations arch t
                 -> SL.ShapedList (FreeParamF Name) sh
                 -> Q Exp
translateFormula ltr ipVarName semantics interps varNames = do
  let preamble = [ bindS (varP (regsValName interps)) [| getRegs |] ]
  exps <- runMacawQ ltr (mapM_ translateDefinition (Map.toList (pfDefs semantics)))
  [| Just $(doSequenceQ preamble exps) |]
  where translateDefinition :: Map.Pair (Parameter arch sh) (S.SymExpr (Sym t))
                            -> MacawQ arch t ()
        translateDefinition (Map.Pair param expr) = do
          case param of
            OperandParameter _w idx -> do
              let FreeParamF name = varNames `SL.indexShapedList` idx
              newVal <- addEltTH interps expr
              appendStmt [| setRegVal (toPPCReg $(varE name)) $(return newVal) |]
            LiteralParameter APPC.LocMem -> writeMemTH interps expr
            LiteralParameter loc -> do
              valExp <- addEltTH interps expr
              appendStmt [| setRegVal $(ltr loc) $(return valExp) |]
            FunctionParameter str (WrappedOperand _ opIx) _w -> do
              let FreeParamF boundOperandName = SL.indexShapedList varNames opIx
              case lookup str (A.locationFuncInterpretation (Proxy @arch)) of
                Nothing -> fail ("Function has no definition: " ++ str)
                Just fi -> do
                  valExp <- addEltTH interps expr
                  appendStmt [| case $(varE (A.exprInterpName fi)) $(varE boundOperandName) of
                                   Just reg -> setRegVal (toPPCReg reg) $(return valExp)
                                   Nothing -> error ("Invalid instruction form at " ++ show $(varE ipVarName))
                               |]

addEltTH :: forall arch t ctp .
            (L.Location arch ~ APPC.Location arch,
             A.Architecture arch,
             1 <= APPC.ArchRegWidth arch,
             M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
         => BoundVarInterpretations arch t
         -> S.Elt t ctp
         -> MacawQ arch t Exp
addEltTH interps elt = do
  mexp <- lookupElt elt
  case mexp of
    Just e -> return e
    Nothing ->
      case elt of
        S.BVElt w val _loc ->
          bindExpr elt [| return (M.BVValue $(natReprTH w) $(lift val)) |]
        S.AppElt appElt -> do
          translatedExpr <- crucAppToExprTH (S.appEltApp appElt) interps
          bindExpr elt [| addExpr =<< $(return translatedExpr) |]
        S.BoundVarElt bVar ->
          case Map.lookup bVar (locVars interps) of
            Just loc -> withLocToReg $ \ltr -> do
              bindExpr elt [| return ($(varE (regsValName interps)) ^. M.boundValue $(ltr loc)) |]
            Nothing  ->
              case Map.lookup bVar (opVars interps) of
                Just (FreeParamF name) -> bindExpr elt [| extractValue $(varE name) |]
                Nothing -> fail $ "bound var not found: " ++ show bVar
        S.NonceAppElt n -> do
          translatedExpr <- evalNonceAppTH interps (S.nonceEltApp n)
          bindExpr elt (return translatedExpr)
        S.SemiRingLiteral {} -> liftQ [| error "SemiRingLiteral Elts are not supported" |]

symFnName :: S.SimpleSymFn t args ret -> String
symFnName = T.unpack . Sy.solverSymbolAsText . S.symFnName

writeMemTH :: forall arch t tp
            . (L.Location arch ~ APPC.Location arch,
                A.Architecture arch,
                1 <= APPC.ArchRegWidth arch,
                M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
           => BoundVarInterpretations arch t
           -> S.Elt t tp
           -> MacawQ arch t ()
writeMemTH bvi expr =
  case expr of
    S.NonceAppElt n ->
      case S.nonceEltApp n of
        S.FnApp symFn args
          | Just memWidth <- matchWriteMemWidth (symFnName symFn) ->
            case FC.toListFC Some args of
              [_, Some addr, Some val] -> do
                addrValExp <- addEltTH bvi addr
                writtenValExp <- addEltTH bvi val
                appendStmt [| addStmt (M.WriteMem $(return addrValExp) (M.BVMemRepr $(natReprFromIntTH memWidth) M.BigEndian) $(return writtenValExp)) |]
              _ -> fail ("Invalid memory write expression: " ++ showF expr)
        _ -> fail ("Unexpected memory definition: " ++ showF expr)
    _ -> fail ("Unexpected memory definition: " ++ showF expr)

-- | Match a "write_mem" intrinsic and return the number of bytes written
matchWriteMemWidth :: String -> Maybe Int
matchWriteMemWidth s = do
  suffix <- L.stripPrefix "write_mem_" s
  (`div` 8) <$> readMaybe suffix

evalNonceAppTH :: forall arch t tp
                . (A.Architecture arch,
                   L.Location arch ~ APPC.Location arch,
                   1 <= APPC.ArchRegWidth arch,
                   M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
               => BoundVarInterpretations arch t
               -> S.NonceApp t (S.Elt t) tp
               -> MacawQ arch t Exp
evalNonceAppTH bvi nonceApp =
  case nonceApp of
    S.FnApp symFn args -> do
      let fnName = symFnName symFn
      -- Recursively evaluate the arguments.  In the recursive evaluator, we
      -- expect two cases:
      --
      -- 1) The argument is a name (via S.BoundVarElt); we want to return a
      -- simple TH expression that just refers to that name
      --
      -- 2) The argument is another call, which we want to evaluate into a
      -- simple TH expression
      --
      -- 3) Otherwise, we can probably just call the standard evaluator on it
      -- (this will probably be the case for read_mem and the floating point
      -- functions)
      --
      -- At the top level (after cases 1 and 2), we need to call 'extractValue' *once*.
      case fnName of
        "ppc_is_r0" -> do
          case FC.toListFC Some args of
            [Some operand] -> do
              -- The operand can be either a variable (TH name bound from
              -- matching on the instruction operand list) or a call on such.
              case operand of
                S.BoundVarElt bv -> do
                  case Map.lookup bv (opVars bvi) of
                    Just (FreeParamF name) -> liftQ [| extractValue (PE.interpIsR0 $(varE name)) |]
                    Nothing -> fail ("bound var not found: " ++ show bv)
                S.NonceAppElt nonceApp' -> do
                  case S.nonceEltApp nonceApp' of
                    S.FnApp symFn' args' -> do
                      let recName = symFnName symFn'
                      case lookup recName (A.locationFuncInterpretation (Proxy @arch)) of
                        Nothing -> fail ("Unsupported UF: " ++ recName)
                        Just fi -> do
                          case FC.toListFC (asName fnName bvi) args' of
                            [] -> fail ("zero-argument uninterpreted functions are not supported: " ++ fnName)
                            argNames -> do
                              let call = appE (varE (A.exprInterpName fi)) $ foldr1 appE (map varE argNames)
                              liftQ [| extractValue (PE.interpIsR0 ($(call))) |]
                    _ -> fail ("Unsupported nonce app type")
                _ -> fail "Unsupported operand to ppc.is_r0"
            _ -> fail ("Invalid argument list for ppc.is_r0: " ++ showF args)
        "test_bit_dynamic" ->
          case FC.toListFC Some args of
            [Some bitNum, Some loc] -> do
              bitNumExp <- addEltTH bvi bitNum
              locExp <- addEltTH bvi loc
              liftQ [| addExpr (AppExpr (M.BVTestBit $(return bitNumExp) $(return locExp))) |]
            _ -> fail ("Unsupported argument list for test_bit_dynamic: " ++ showF args)
        -- For count leading zeros, we don't have a SimpleBuilder term to reduce
        -- it to, so we have to manually transform it to macaw here (i.e., we
        -- can't use the more general substitution method, since that is in
        -- terms of rewriting simplebuilder).
        "clz_32" ->
          case FC.toListFC Some args of
            [Some loc] -> do
              locExp <- addEltTH bvi loc
              liftQ [| addExpr (AppExpr (M.Bsr (NR.knownNat @32) $(return locExp))) |]
            _ -> fail ("Unsupported argument list for clz: " ++ showF args)
        "clz_64" ->
          case FC.toListFC Some args of
            [Some loc] -> do
              locExp <- addEltTH bvi loc
              liftQ [| addExpr (AppExpr (M.Bsr (NR.knownNat @64) $(return locExp))) |]
            _ -> fail ("Unsupported argument list for clz: " ++ showF args)
        "popcnt_32" ->
          case FC.toListFC Some args of
            [Some loc] -> do
              locExp <- addEltTH bvi loc
              liftQ [| addExpr (AppExpr (M.PopCount (NR.knownNat @32) $(return locExp))) |]
            _ -> fail ("Unsupported argument list for popcnt: " ++ showF args)
        "popcnt_64" ->
          case FC.toListFC Some args of
            [Some loc] -> do
              locExp <- addEltTH bvi loc
              liftQ [| addExpr (AppExpr (M.PopCount (NR.knownNat @64) $(return locExp))) |]
            _ -> fail ("Unsupported argument list for popcnt: " ++ showF args)
        "undefined" -> do
          case S.nonceAppType nonceApp of
            CT.BaseBVRepr n ->
              liftQ [| M.AssignedValue <$> addAssignment (M.SetUndefined (M.BVTypeRepr $(natReprTH n))) |]
            nt -> fail ("Invalid type for undefined: " ++ show nt)
        _ | Just nBytes <- readMemBytes fnName -> do
            case FC.toListFC Some args of
              [_, Some addrElt] -> do
                -- read_mem has a shape such that we expect two arguments; the
                -- first is just a stand-in in the semantics to represent the
                -- memory.
                addr <- addEltTH bvi addrElt
                liftQ [| let memRep = M.BVMemRepr (NR.knownNat :: NR.NatRepr $(litT (numTyLit (fromIntegral nBytes)))) M.BigEndian
                        in M.AssignedValue <$> addAssignment (M.ReadMem $(return addr) memRep)
                       |]
              _ -> fail ("Unexpected arguments to read_mem: " ++ showF args)
          | Just fpFunc <- elementaryFPName fnName -> floatingPointTH bvi fpFunc args
          | otherwise ->
            case lookup fnName (A.locationFuncInterpretation (Proxy @arch)) of
              Nothing -> liftQ [| error ("Unsupported UF: " ++ show $(litE (StringL fnName))) |]
              Just fi -> do
                -- args is an assignment that contains elts; we could just generate
                -- expressions that evaluate each one and then splat them into new names
                -- that we apply our name to.
                case FC.toListFC (asName fnName bvi) args of
                  [] -> fail ("zero-argument uninterpreted functions are not supported: " ++ fnName)
                  argNames -> do
                    let call = appE (varE (A.exprInterpName fi)) $ foldr1 appE (map varE argNames)
                    liftQ [| extractValue ($(call)) |]
    _ -> liftQ [| error "Unsupported NonceApp case" |]

elementaryFPName :: String -> Maybe String
elementaryFPName = L.stripPrefix "fp_"

floatingPointTH :: forall arch t f c
                 . (L.Location arch ~ APPC.Location arch,
                     A.Architecture arch,
                     1 <= APPC.ArchRegWidth arch,
                     M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch,
                     FC.FoldableFC f)
                 => BoundVarInterpretations arch t
                 -> String
                 -> f (S.Elt t) c
                 -> MacawQ arch t Exp
floatingPointTH bvi fnName args =
  case FC.toListFC Some args of
    [Some a] ->
      case fnName of
        "round_single" -> do
          fpval <- addEltTH bvi a
          liftQ [| addExpr (AppExpr (M.FPCvt M.DoubleFloatRepr $(return fpval) M.SingleFloatRepr)) |]
        "single_to_double" -> do
          fpval <- addEltTH bvi a
          liftQ [| addExpr (AppExpr (M.FPCvt M.SingleFloatRepr $(return fpval) M.DoubleFloatRepr)) |]
        "abs" -> do
          -- Note that fabs is only defined for doubles; the operation is the
          -- same for single and double precision on PPC, so there is only a
          -- single instruction.
          fpval <- addEltTH bvi a
          liftQ [| addExpr (AppExpr (M.FPAbs M.DoubleFloatRepr $(return fpval))) |]
        "negate64" -> do
          fpval <- addEltTH bvi a
          liftQ [| addExpr (AppExpr (M.FPNeg M.DoubleFloatRepr $(return fpval))) |]
        "negate32" -> do
          fpval <- addEltTH bvi a
          liftQ [| addExpr (AppExpr (M.FPNeg M.SingleFloatRepr $(return fpval))) |]
        "is_snan32" -> do
          fpval <- addEltTH bvi a
          liftQ [| addExpr (AppExpr (M.FPIsSNaN M.SingleFloatRepr $(return fpval))) |]
        "is_snan64" -> do
          fpval <- addEltTH bvi a
          liftQ [| addExpr (AppExpr (M.FPIsSNaN M.DoubleFloatRepr $(return fpval))) |]
        _ -> fail ("Unsupported unary floating point intrinsic: " ++ fnName)
    [Some a, Some b] ->
      case fnName of
        "add64" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPAdd M.DoubleFloatRepr $(return valA) $(return valB))) |]
        "add32" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPAdd M.SingleFloatRepr $(return valA) $(return valB))) |]
        "sub64" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPSub M.DoubleFloatRepr $(return valA) $(return valB))) |]
        "sub32" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPSub M.SingleFloatRepr $(return valA) $(return valB))) |]
        "mul64" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPMul M.DoubleFloatRepr $(return valA) $(return valB))) |]
        "mul32" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPMul M.SingleFloatRepr $(return valA) $(return valB))) |]
        "div64" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPDiv M.DoubleFloatRepr $(return valA) $(return valB))) |]
        "div32" -> do
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          liftQ [| addExpr (AppExpr (M.FPDiv M.SingleFloatRepr $(return valA) $(return valB))) |]
        _ -> fail ("Unsupported binary floating point intrinsic: " ++ fnName)
    [Some a, Some b, Some c] ->
      case fnName of
        "muladd64" -> do
          -- FIXME: This is very wrong - we need a separate constructor for it
          -- a * c + b
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          valC <- addEltTH bvi c
          liftQ [| do prodVal <- addExpr (AppExpr (M.FPMul M.DoubleFloatRepr $(return valA) $(return valC)))
                      addExpr (AppExpr (M.FPAdd M.DoubleFloatRepr prodVal $(return valB)))
                 |]
        "muladd32" -> do
          -- a * c + b
          valA <- addEltTH bvi a
          valB <- addEltTH bvi b
          valC <- addEltTH bvi c
          liftQ [| do prodVal <- addExpr (AppExpr (M.FPMul M.SingleFloatRepr $(return valA) $(return valC)))
                      addExpr (AppExpr (M.FPAdd M.SingleFloatRepr prodVal $(return valB)))
                 |]
        _ -> fail ("Unsupported ternary floating point intrinsic: " ++ fnName)
    _ -> fail ("Unsupported floating point intrinsic: " ++ fnName)

-- | Parse the name of a memory read intrinsic and return the number of bytes
-- that it reads.  For example
--
-- > readMemBytes "read_mem_8" == Just 1
readMemBytes :: String -> Maybe Int
readMemBytes s = do
  nBitsStr <- L.stripPrefix "read_mem_" s
  nBits <- readMaybe nBitsStr
  return (nBits `div` 8)

asName :: String -> BoundVarInterpretations arch t -> S.Elt t tp -> Name
asName ufName bvInterps elt =
  case elt of
    S.BoundVarElt bVar ->
      case Map.lookup bVar (opVars bvInterps) of
        Nothing -> error ("Expected " ++ show bVar ++ " to have an interpretation")
        Just (FreeParamF name) -> name
    _ -> error ("Unexpected elt as name (" ++ showF elt ++ ") in " ++ ufName)

-- Unimplemented:

-- Don't need to implement:
--   - all SemiRing operations (not using)
--   - all "Basic arithmetic operations" (not using)
--   - all "Operations that introduce irrational numbers" (not using)
--   - BVUnaryTerm (not using)
--   - all array operations (probably not using)
--   - all conversions
--   - all complex operations
--   - all structs

-- Might need to implement later:
--   - BVUdiv, BVUrem, BVSdiv, BVSrem
crucAppToExprTH :: (L.Location arch ~ APPC.Location arch,
                    A.Architecture arch,
                   1 <= APPC.ArchRegWidth arch,
                   M.RegAddrWidth (PPCReg arch) ~ APPC.ArchRegWidth arch)
                => S.App (S.Elt t) ctp
                -> BoundVarInterpretations arch t
                -> MacawQ arch t Exp
crucAppToExprTH elt interps = case elt of
  S.TrueBool  -> liftQ [| return $ ValueExpr (M.BoolValue True) |]
  S.FalseBool -> liftQ [| return $ ValueExpr (M.BoolValue False) |]
  S.NotBool bool -> do
    e <- addEltTH interps bool
    liftQ [| return (AppExpr (M.NotApp $(return e))) |]
  S.AndBool bool1 bool2 -> do
    e1 <- addEltTH interps bool1
    e2 <- addEltTH interps bool2
    liftQ [| return (AppExpr (M.AndApp $(return e1) $(return e2))) |]
  S.XorBool bool1 bool2 -> do
    e1 <- addEltTH interps bool1
    e2 <- addEltTH interps bool2
    liftQ [| return (AppExpr (M.XorApp $(return e1) $(return e2))) |]
  S.IteBool test t f -> do
    testE <- addEltTH interps test
    tE <- addEltTH interps t
    fE <- addEltTH interps f
    liftQ [| return (AppExpr (M.Mux M.BoolTypeRepr $(return testE) $(return tE) $(return fE))) |]
  S.BVIte w _ test t f -> do
    testE <- addEltTH interps test
    tE <- addEltTH interps t
    fE <- addEltTH interps f
    liftQ [| return (AppExpr (M.Mux (M.BVTypeRepr $(natReprTH w)) $(return testE) $(return tE) $(return fE))) |]
  S.BVEq bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.Eq $(return e1) $(return e2))) |]
  S.BVSlt bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVSignedLt $(return e1) $(return e2))) |]
  S.BVUlt bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVUnsignedLt $(return e1) $(return e2))) |]
  S.BVConcat w bv1 bv2 -> do
    let u = S.bvWidth bv1
        v = S.bvWidth bv2
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| bvconcat $(return e1) $(return e2) $(natReprTH v) $(natReprTH u) $(natReprTH w) |]
  S.BVSelect idx n bv -> do
    let w = S.bvWidth bv
    case natValue n + 1 <= natValue w of
      True -> do
        e <- addEltTH interps bv
        liftQ [| bvselect $(return e) $(natReprTH n) $(natReprTH idx) $(natReprTH w) |]
      False -> do
        e <- addEltTH interps bv
        liftQ [| case testEquality $(natReprTH n) $(natReprTH w) of
                   Just Refl -> return (ValueExpr $(return e))
                   Nothing -> error "Invalid reprs for BVSelect translation"
               |]
  S.BVNeg w bv -> do
    bvValExp <- addEltTH interps bv
    liftQ [| let repW = $(natReprTH w)
             in AppExpr <$> (M.BVAdd repW <$> addExpr (AppExpr (M.BVComplement repW $(return bvValExp))) <*> pure (M.mkLit repW 1))
           |]
  S.BVTestBit idx bv -> do
    bvValExp <- addEltTH interps bv
    liftQ [| AppExpr <$> (M.BVTestBit <$> addExpr (ValueExpr (M.BVValue $(natReprTH (S.bvWidth bv)) $(lift idx))) <*> pure $(return bvValExp)) |]
  S.BVAdd w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVAdd $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVMul w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVMul $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVSdiv w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| let divExp = SDiv $(natReprTH w) $(return e1) $(return e2)
             in (ValueExpr . M.AssignedValue) <$> addAssignment (M.EvalArchFn divExp (M.typeRepr divExp))
           |]
  S.BVUdiv w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| let divExp = UDiv $(natReprTH w) $(return e1) $(return e2)
             in (ValueExpr . M.AssignedValue) <$> addAssignment (M.EvalArchFn divExp (M.typeRepr divExp))
           |]
  S.BVShl w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVShl $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVLshr w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVShr $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVAshr w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVSar $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVZext w bv -> do
    e <- addEltTH interps bv
    liftQ [| return (AppExpr (M.UExt $(return e) $(natReprTH w))) |]
  S.BVSext w bv -> do
    e <- addEltTH interps bv
    liftQ [| return (AppExpr (M.SExt $(return e) $(natReprTH w))) |]
  S.BVTrunc w bv -> do
    e <- addEltTH interps bv
    liftQ [| return (AppExpr (M.Trunc $(return e) $(natReprTH w))) |]
  S.BVBitNot w bv -> do
    e <- addEltTH interps bv
    liftQ [| return (AppExpr (M.BVComplement $(natReprTH w) $(return e))) |]
  S.BVBitAnd w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVAnd $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVBitOr w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVOr $(natReprTH w) $(return e1) $(return e2))) |]
  S.BVBitXor w bv1 bv2 -> do
    e1 <- addEltTH interps bv1
    e2 <- addEltTH interps bv2
    liftQ [| return (AppExpr (M.BVXor $(natReprTH w) $(return e1) $(return e2))) |]
  _ -> liftQ [| error "unsupported Crucible elt" |]

