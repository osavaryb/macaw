{-
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>, Simon Winwood <sjw@galois.com>

This defines the X86_64 architecture type and the supporting definitions.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module Data.Macaw.X86.ArchTypes
  ( -- * Architecture
    X86_64
  , X86PrimFn(..)
  , X87_FloatType(..)
  , SSE_FloatType(..)
  , SSE_Cmp(..)
  , lookupSSECmp
  , SSE_Op(..)
  , AVXPointWiseOp2(..)
  , AVXOp1(..)
  , AVXOp2(..)
  , sseOpName
  , rewriteX86PrimFn
  , x86PrimFnHasSideEffects
  , X86Stmt(..)
  , rewriteX86Stmt
  , X86TermStmt(..)
  , rewriteX86TermStmt
  , X86PrimLoc(..)
  , SIMDWidth(..)
  , RepValSize(..)
  , repValSizeByteCount
  , repValSizeMemRepr
  ) where

import           Data.Bits
import qualified Data.Kind as Kind
import           Data.Word(Word8)
import           Data.Macaw.CFG
import           Data.Macaw.CFG.Rewriter
import           Data.Macaw.Memory (Endianness(..))
import           Data.Macaw.Types
import qualified Data.Map as Map
import           Data.Parameterized.Classes
import           Data.Parameterized.NatRepr
import           Data.Parameterized.TraversableF
import           Data.Parameterized.TraversableFC
import qualified Flexdis86 as F
import           Text.PrettyPrint.ANSI.Leijen as PP hiding ((<$>))

import           Data.Macaw.X86.X86Reg
import           Data.Macaw.X86.X87ControlReg

------------------------------------------------------------------------
-- SIMDWidth

-- | Defines a width of a register associated with SIMD operations
-- (e.g., MMX, XMM, AVX)
data SIMDWidth w
   = (w ~  64) => SIMD_64
   | (w ~ 128) => SIMD_128
   | (w ~ 256) => SIMD_256

-- | Return the 'NatRepr' associated with the given width.
instance HasRepr SIMDWidth NatRepr where
  typeRepr SIMD_64  = knownNat
  typeRepr SIMD_128 = knownNat
  typeRepr SIMD_256 = knownNat

------------------------------------------------------------------------
-- RepValSize

-- | A value for distinguishing between 1,2,4 and 8 byte values.
data RepValSize w
   = (w ~  8) => ByteRepVal
   | (w ~ 16) => WordRepVal
   | (w ~ 32) => DWordRepVal
   | (w ~ 64) => QWordRepVal

repValSizeMemRepr :: RepValSize w -> MemRepr (BVType w)
repValSizeMemRepr v =
  case v of
    ByteRepVal  -> BVMemRepr (knownNat :: NatRepr 1) LittleEndian
    WordRepVal  -> BVMemRepr (knownNat :: NatRepr 2) LittleEndian
    DWordRepVal -> BVMemRepr (knownNat :: NatRepr 4) LittleEndian
    QWordRepVal -> BVMemRepr (knownNat :: NatRepr 8) LittleEndian

repValSizeByteCount :: RepValSize w -> Integer
repValSizeByteCount = memReprBytes . repValSizeMemRepr

------------------------------------------------------------------------
-- X86TermStmt

data X86TermStmt ids
   = X86Syscall
     -- ^ A system call
   | Hlt
     -- ^ The halt instruction.
     --
     -- In protected mode outside ring 0, this just raised a GP(0) exception.
   | UD2
     -- ^ This raises a invalid opcode instruction.

instance PrettyF X86TermStmt where
  prettyF X86Syscall = text "x86_syscall"
  prettyF Hlt        = text "hlt"
  prettyF UD2        = text "ud2"

------------------------------------------------------------------------
-- X86PrimLoc

-- | This describes a primitive location that can be read or written to in the
--  X86 architecture model.
-- Primitive locations are not modeled as registers, but rather as implicit state.
data X86PrimLoc tp
   = (tp ~ BVType 64) => ControlLoc !F.ControlReg
   | (tp ~ BVType 64) => DebugLoc   !F.DebugReg
   | (tp ~ BVType 16) => FS
     -- ^ This refers to the selector of the 'FS' register.
   | (tp ~ BVType 16) => GS
     -- ^ This refers to the se lector of the 'GS' register.
   | forall w . (tp ~ BVType   w) => X87_ControlLoc !(X87_ControlReg w)
     -- ^ One of the x87 control registers

instance HasRepr X86PrimLoc TypeRepr where
  typeRepr ControlLoc{} = knownRepr
  typeRepr DebugLoc{}   = knownRepr
  typeRepr FS = knownRepr
  typeRepr GS = knownRepr
  typeRepr (X87_ControlLoc r) =
    case x87ControlRegWidthIsPos r of
      LeqProof -> BVTypeRepr (typeRepr r)

instance Pretty (X86PrimLoc tp) where
  pretty (ControlLoc r) = text (show r)
  pretty (DebugLoc r) = text (show r)
  pretty FS = text "fs"
  pretty GS = text "gs"
  pretty (X87_ControlLoc r) = text (show r)

------------------------------------------------------------------------
-- SSE declarations

-- | A comparison of two values.
data SSE_Cmp
   = EQ_OQ
     -- ^ Two values are equal, no signalling on QNaN
   | LT_OS
     -- ^ First value less than second, signal on QNaN
   | LE_OS
     -- ^ First value less than or equal to second, signal on QNaN
   | UNORD_Q
     -- ^ Either value is a NaN, no signalling on QNaN
   | NEQ_UQ
     -- ^ Not equal, no signal on QNaN
   | NLT_US
     -- ^ Not less than, signal on QNaN
   | NLE_US
     -- ^ Not less than or equal, signal on QNaN
   | ORD_Q
     -- ^ Neither value is a NaN, no signalling on QNaN
  deriving (Eq, Ord)

sseCmpEntries :: [(Word8, SSE_Cmp, String)]
sseCmpEntries =
  [ (0, EQ_OQ,   "EQ_OQ")
  , (1, LT_OS,   "LT_OS")
  , (2, LE_OS  , "LE_OS")
  , (3, UNORD_Q, "UNORD_Q")
  , (4, NEQ_UQ,  "NEQ_UQ")
  , (5, NLT_US,  "NLT_US")
  , (6, NLE_US,  "NLE_US")
  , (7, ORD_Q,   "ORD_Q")
  ]

sseIdxCmpMap :: Map.Map Word8 SSE_Cmp
sseIdxCmpMap = Map.fromList [ (idx,val) | (idx, val, _) <- sseCmpEntries ]

sseCmpNameMap :: Map.Map SSE_Cmp String
sseCmpNameMap = Map.fromList [ (val, nm) | (_, val, nm) <- sseCmpEntries ]

instance Show SSE_Cmp where
  show c  =
    case Map.lookup c sseCmpNameMap of
      Just nm -> nm
      -- The nothing case should never occur.
      Nothing -> "Unexpected name"

lookupSSECmp :: Word8 -> Maybe SSE_Cmp
lookupSSECmp i = Map.lookup i sseIdxCmpMap

-- | A binary SSE operation
data SSE_Op
   = SSE_Add
   | SSE_Sub
   | SSE_Mul
   | SSE_Div
   | SSE_Min
   | SSE_Max
   | SSE_Sqrt

-- | Return the name of the mnemonic associated with the SSE op.
sseOpName :: SSE_Op -> String
sseOpName f =
  case f of
    SSE_Add -> "add"
    SSE_Sub -> "sub"
    SSE_Mul -> "mul"
    SSE_Div -> "div"
    SSE_Min -> "min"
    SSE_Max -> "max"
    SSE_Sqrt -> "sqrt"

-- | A single or double value for floating-point restricted to this types.
data SSE_FloatType tp where
   SSE_Single :: SSE_FloatType (FloatBVType SingleFloat)
   SSE_Double :: SSE_FloatType (FloatBVType DoubleFloat)

instance Show (SSE_FloatType tp) where
  show SSE_Single = "single"
  show SSE_Double = "double"

instance HasRepr SSE_FloatType TypeRepr where
  typeRepr SSE_Single = knownRepr
  typeRepr SSE_Double = knownRepr

------------------------------------------------------------------------
-- X87 declarations

data X87_FloatType tp where
   X87_Single :: X87_FloatType (FloatBVType SingleFloat)
   X87_Double :: X87_FloatType (FloatBVType DoubleFloat)
   X87_ExtDouble :: X87_FloatType (FloatBVType X86_80Float)

instance Show (X87_FloatType tp) where
  show X87_Single = "single"
  show X87_Double = "double"
  show X87_ExtDouble = "extdouble"

------------------------------------------------------------------------

data AVXOp1 = VShiftL Word8     -- ^ Shift left by this many bytes
                                -- New bytes are 0.
            | VShiftR Word8     -- ^ Shift right by this many bytes.
                                -- New bytes are 0.
            | VShufD Word8      -- ^ Shuffle 32-bit words of vector
                                -- according to pattern in the word8

data AVXOp2 = VPAnd             -- ^ Bitwise and
            | VPOr              -- ^ Bitwise or
            | VPXor             -- ^ Bitwise xor
            | VPAlignR Word8    -- ^ Concatenate inputs (1st most sign)
                                -- then shift right by the given amount
                                -- in bytes.
            | VPShufB           -- ^ First operand is a vector,
                                -- second is the shuffle-control-mask
            | VAESEnc           -- ^ 1st op: state, 2nd op: key schedule
            | VAESEncLast       -- ^ 1st op: state, 2nd op: key schedule
            | VPCLMULQDQ Word8
              {- ^ Carry-less multiplication of quadwords
                The operand specifies which 64-bit words of the input
                vectors to multiply as follows:

                  * lower 4 bits -> index in 1st op;
                  * upper 4 bits -> index in 2nd op;

                 Indexes are always 0 or 1. -}

            | VPUnpackLQDQ
              -- ^ @A,B,C,D + P,Q,R,S = C,R,D,S@
              -- This one is for DQ, i.e., 64-bit things
              -- but there are equivalents for all sizes, so we should
              -- probably parameterize on size.


data AVXPointWiseOp2 =
    PtAdd -- ^ Pointwise add;  overflow wraps around; no overflow flags
  | PtSub -- ^ Pointwise subtract; overflow wraps around; no overflow flags

instance Show AVXOp1 where
  show x = case x of
             VShiftL i -> "vshiftl_" ++ show i
             VShiftR i -> "vshiftr_" ++ show i
             VShufD  i -> "vshufd_" ++ show i

instance Show AVXOp2 where
  show x = case x of
             VPAnd        -> "vpand"
             VPOr         -> "vpor"
             VPXor        -> "vpxor"
             VPAlignR i   -> "vpalignr_" ++ show i
             VPShufB      -> "vpshufb"
             VAESEnc      -> "vaesenc"
             VAESEncLast  -> "vaesenclast"
             VPCLMULQDQ i -> "vpclmulqdq_" ++ show i
             VPUnpackLQDQ -> "vpunpacklqdq"

instance Show AVXPointWiseOp2 where
  show x = case x of
             PtAdd -> "ptadd"
             PtSub -> "ptsub"

------------------------------------------------------------------------
-- X86PrimFn

-- | Defines primitive functions in the X86 format.
data X86PrimFn f tp where

  -- | Return true if the operand has an even number of bits set.
  EvenParity :: !(f (BVType 8)) -> X86PrimFn f BoolType

  -- | Read from a primitive X86 location.
  ReadLoc :: !(X86PrimLoc tp) -> X86PrimFn f tp

  -- | Read the 'FS' base address.
  ReadFSBase :: X86PrimFn f (BVType 64)

  -- | Read the 'GS' base address.
  ReadGSBase :: X86PrimFn f (BVType 64)

  -- | The CPUID instruction.
  --
  -- Given value in eax register, this returns the concatenation of eax:ebx:ecx:edx.
  CPUID :: !(f (BVType 32)) -> X86PrimFn f (BVType 128)

  -- | This implements the logic for the cmpxchg8b instruction
  --
  -- Given a statement, `CMPXCHG8B addr eax ebx ecx edx` this executes the following logic:
  --
  -- >   temp64 <- read addr
  -- >   if edx:eax == tmp then do
  -- >     *addr := ecx:ebx
  -- >     return (true, eax, edx)
  -- >   else
  -- >     return (false, trunc 32 temp64, trunc 32 (temp64 >> 32))
  --
  CMPXCHG8B :: !(f (BVType 64))
               -- Address to read
            -> !(f (BVType 32))
               -- Value in EAX
            -> !(f (BVType 32))
               -- Value in EBX
            -> !(f (BVType 32))
               -- Value in ECX
            -> !(f (BVType 32))
               -- Value in EDX
            -> X86PrimFn f (TupleType [BoolType, BVType 32, BVType 32])

  -- | The RDTSC instruction.
  --
  -- This returns the current time stamp counter a 64-bit value that will
  -- be stored in edx:eax
  RDTSC :: X86PrimFn f (BVType 64)

  -- | The XGetBV instruction primitive
  --
  -- This returns the extended control register defined in the given value
  -- as a 64-bit value that will be stored in edx:eax
  XGetBV :: !(f (BVType 32)) -> X86PrimFn f (BVType 64)

  -- | @PShufb w x s@ returns a value @res@ generated from the bytes of @x@
  -- based on indices defined in the corresponding bytes of @s@.
  --
  -- Let @n@ be the number of bytes in the width @w@, and let @l = log2(n)@.
  -- Given a byte index @i@, the value of byte @res[i]@, is defined by
  --   @res[i] = 0 if msb(s[i]) == 1@
  --   @res[i] = x[j] where j = s[i](0..l)
  -- where @msb(y)@ returns the most-significant bit in byte @y@.
  PShufb :: (1 <= w) => !(SIMDWidth w) -> !(f (BVType w)) -> !(f (BVType w)) -> X86PrimFn f (BVType w)

  -- | Compares two memory regions and return the number of bytes that were the same.
  --
  -- In an expression @MemCmp bpv nv p1 p2 dir@:
  --
  -- * @bpv@ is the number of bytes per value
  -- * @nv@ is the number of values to compare
  -- * @p1@ is the pointer to the first buffer
  -- * @p2@ is the pointer to the second buffer
  -- * @dir@ is a flag that indicates the direction of comparison ('True' ==
  --   decrement, 'False' == increment) for updating the buffer
  --   pointers.
  MemCmp :: !Integer
         -> !(f (BVType 64))
         -> !(f (BVType 64))
         -> !(f (BVType 64))
         -> !(f BoolType)
         -> X86PrimFn f (BVType 64)

  -- | `RepnzScas sz val base cnt` searchs through a buffer starting at
  -- `base` to find  an element `i` such that base[i] = val.
  -- Each step it increments `i` by 1 and decrements `cnt` by `1`.
  -- It returns the final value of `cnt`.
  RepnzScas :: !(RepValSize n)
            -> !(f (BVType n))
            -> !(f (BVType 64))
            -> !(f (BVType 64))
            -> X86PrimFn f (BVType 64)

  -- | This returns a 80-bit value where the high 16-bits are all
  -- 1s, and the low 64-bits are the given register.
  MMXExtend :: !(f (BVType 64)) -> X86PrimFn f (BVType 80)

  -- | This performs a signed quotient for idiv.
  -- It raises a #DE exception if the divisor is 0 or the result overflows.
  -- The stored result is truncated to zero.
  X86IDiv :: !(RepValSize w)
          -> !(f (BVType (w+w)))
          -> !(f (BVType w))
          -> X86PrimFn f (BVType w)

  -- | This performs a signed remainder for idiv.
  -- It raises a #DE exception if the divisor is 0 or the quotient overflows.
  -- The stored result is truncated to zero.

  X86IRem :: !(RepValSize w)
          -> !(f (BVType (w+w)))
          -> !(f (BVType w))
          -> X86PrimFn f (BVType w)

  -- | This performs a unsigned quotient for div.
  -- It raises a #DE exception if the divisor is 0 or the quotient overflows.
  X86Div :: !(RepValSize w)
         -> !(f (BVType (w+w)))
         -> !(f (BVType w))
         -> X86PrimFn f (BVType w)

  -- | This performs an unsigned remainder for div.
  -- It raises a #DE exception if the divisor is 0 or the quotient overflows.
  X86Rem :: !(RepValSize w)
         -> !(f (BVType (w+w)))
         -> !(f (BVType w))
         -> X86PrimFn f (BVType w)

  -- | This applies the operation pairwise to two vectors of floating point values.
  --
  -- This function implicitly depends on the MXCSR register and may
  -- signal exceptions as noted in the documentation on SSE.
  SSE_VectorOp :: (1 <= n, 1 <= w)
               => !SSE_Op
               -> !(NatRepr n)
               -> !(SSE_FloatType (BVType w))
               -> !(f (BVType (n*w)))
               -> !(f (BVType (n*w)))
               -> X86PrimFn f (BVType (n*w))

  -- | This performs a comparison between the two instructions (as
  -- needed by the CMPSD and CMPSS instructions.
  --
  -- This implicitly depends on the MXCSR register as it may throw
  -- exceptions when given signaling NaNs or denormals when the
  -- appropriate bits are set on the MXCSR register.
  SSE_CMPSX :: !SSE_Cmp
            -> !(SSE_FloatType tp)
            -> !(f tp)
            -> !(f tp)
            -> X86PrimFn f tp

  -- |  This performs a comparison of two floating point values and returns three flags:
  --
  --  * ZF is for the zero-flag and true if the arguments are equal or either argument is a NaN.
  --
  --  * PF records the unordered flag and is true if either value is a NaN.
  --
  --  * CF is the carry flag, and true if the first floating point argument is less than
  --    second or either value is a NaN.
  --
  -- The order of the flags was chosen to be consistent with the Intel documentation for
  -- UCOMISD and UCOMISS.
  --
  -- This function implicitly depends on the MXCSR register and may signal exceptions based
  -- on the configuration of that register.
  SSE_UCOMIS :: !(SSE_FloatType tp)
             -> !(f tp)
             -> !(f tp)
             -> X86PrimFn f (TupleType [BoolType, BoolType, BoolType])

  -- | This converts a single to a double precision number.
  --
  -- This function implicitly depends on the MXCSR register and may
  -- signal a exception based on the configuration of that
  -- register.
  SSE_CVTSS2SD :: !(f (BVType 32)) -> X86PrimFn f (BVType 64)

  -- | This converts a double to a single precision number.
  --
  -- This function implicitly depends on the MXCSR register and may
  -- signal a exception based on the configuration of that
  -- register.
  SSE_CVTSD2SS :: !(f (BVType 64)) -> X86PrimFn f (BVType 32)

  -- | This converts a floating point value to a bitvector of the
  -- given width (should be 32 or 64)
  --
  -- This function implicitly depends on the MXCSR register and may
  -- signal exceptions based on the configuration of that register.
  SSE_CVTTSX2SI
    :: (1 <= w)
    => !(NatRepr w)
    -> !(SSE_FloatType tp)
    -> !(f tp)
    -> X86PrimFn f (BVType w)

  -- | This converts a signed integer to a floating point value of
  -- the given type  (the input width should be 32 or 64)
  --
  -- This function implicitly depends on the MXCSR register and may
  -- signal a precision exception based on the configuration of that
  -- register.
  SSE_CVTSI2SX    :: (1 <= w)
    => !(SSE_FloatType tp)
    -> !(NatRepr w)
    -> !(f (BVType w))
    -> X86PrimFn f tp

  -- | Extends a single or double to 80-bit precision.
  -- Guaranteed to not throw exception or have side effects.
  X87_Extend :: !(SSE_FloatType tp)
             -> !(f tp)
             -> X86PrimFn f (FloatBVType X86_80Float)

  -- | This performs an 80-bit floating point add.
  --
  -- This returns the result and a Boolean flag indicating if the
  -- result was rounded up.
  --
  -- This computation implicitly depends on the x87 FPU control word,
  -- and may throw any of the following exceptions:
  --
  -- * @#IA@ Operand is an SNaN value or unsupported format.
  --     Operands are infinities of unlike sign.
  -- * @#D@  Source operand is a denormal value.
  -- * @#U@ Result is too small for destination format.
  -- * @#O@ Result is too large for destination format.
  -- * @#P@ Value cannot be represented exactly in destination format.
  X87_FAdd :: !(f (FloatBVType X86_80Float))
           -> !(f (FloatBVType X86_80Float))
           -> X86PrimFn f (TupleType [FloatBVType X86_80Float, BoolType])

  -- | This performs an 80-bit floating point subtraction.
  --
  -- This returns the result and a Boolean flag indicating if the
  -- result was rounded up.
  --
  -- This computation implicitly depends on the x87 FPU control word,
  -- and may throw any of the following exceptions:
  --
  -- * @#IA@ Operand is an SNaN value or unsupported format.
  --     Operands are infinities of unlike sign.
  -- * @#D@  Source operand is a denormal value.
  -- * @#U@ Result is too small for destination format.
  -- * @#O@ Result is too large for destination format.
  -- * @#P@ Value cannot be represented exactly in destination format.
  X87_FSub :: !(f (FloatBVType X86_80Float))
           -> !(f (FloatBVType X86_80Float))
           -> X86PrimFn f (TupleType [FloatBVType X86_80Float, BoolType])

  -- | This performs an 80-bit floating point multiply.
  --
  -- This returns the result and a Boolean flag indicating if the
  -- result was rounded up.
  --
  -- This computation implicitly depends on the x87 FPU control word,
  -- and may throw any of the following exceptions:
  --
  -- * @#IA@ Operand is an SNaN value or unsupported format.
  --     Operands are infinities of unlike sign.
  -- * @#D@  Source operand is a denormal value.
  -- * @#U@ Result is too small for destination format.
  -- * @#O@ Result is too large for destination format.
  -- * @#P@ Value cannot be represented exactly in destination format.
  X87_FMul :: !(f (FloatBVType X86_80Float))
           -> !(f (FloatBVType X86_80Float))
           -> X86PrimFn f (TupleType [FloatBVType X86_80Float, BoolType])

  -- | This rounds a floating number to single or double precision.
  --
  -- This instruction rounds according to the x87 FPU control word
  -- rounding mode, and may throw any of the following exceptions:
  --
  -- * @#O@ is generated if the input value overflows and cannot be
  --   stored in the output format.
  -- * @#U@ is generated if the computation underflows and cannot be
  --   represented (this is in lieu of a denormal exception #D).
  -- * @#IA@ If destination result is an SNaN value or unsupported format.
  -- * @#P@ Value cannot be represented exactly in destination format.
  --   In the #P case, the C1 register will be set 1 if rounding up,
  --   and 0 otherwise.
  X87_FST :: !(SSE_FloatType tp)
          -> !(f (FloatBVType X86_80Float))
          -> X86PrimFn f tp

  -- | Unary operation on a vector.  Should have no side effects.
  --
  -- For the expression @VOp1 w op tgt@:
  --
  -- * @w@ is the width of the input/result vector
  -- * @op@ is the operation to perform
  -- * @tgt@ is the target vector of the operation
  VOp1 :: (1 <= n) =>
     !(NatRepr n)        ->
     !AVXOp1             ->
     !(f (BVType n))     ->
     X86PrimFn f (BVType n)

  -- | Binary operation on two vectors. Should not have side effects.
  --
  -- For the expression @VOp2 w op vec1 vec2@:
  --
  -- * @w@ is the width of the vectors
  -- * @op@ is the binary operation to perform on the vectors
  -- * @vec1@ is the first vector
  -- * @vec2@ is the second vector
  VOp2 :: (1 <= n) =>
    !(NatRepr n)    ->
    !AVXOp2         ->
    !(f (BVType n)) ->
    !(f (BVType n)) ->
    X86PrimFn f (BVType n)

  -- | Update an element of a vector.
  --
  -- For the expression @VInsert n w vec val idx@:
  --
  -- * @n@ is the number of elements in the vector
  -- * @w@ is the size of each element in bits
  -- * @vec@ is the vector to be inserted into
  -- * @val@ is the value to be inserted
  -- * @idx@ is the index to insert at
  VInsert :: (1 <= elSize, 1 <= elNum, (i + 1) <= elNum) =>
             !(NatRepr elNum)
          -> !(NatRepr elSize)
          -> !(f (BVType (elNum * elSize)))
          -> !(f (BVType elSize))
          -> !(NatRepr i)
          -> X86PrimFn f (BVType (elNum * elSize))

  -- | Shift left each element in the vector by the given amount.
  -- The new ("shifted-in") bits are 0.
  --
  -- For the expression @PointwiseShiftL n w amtw vec amt@:
  --
  -- * @n@ is the number of elements in the vector
  -- * @w@ is the size of each element in bits
  -- * @amtw@ is the size of the shift amount in bits
  -- * @vec@ is the vector to be inserted into
  -- * @amt@ is the shift amount in bits
  PointwiseShiftL :: (1 <= elSize, 1 <= elNum, 1 <= sz) =>
                     !(NatRepr elNum)
                  -> !(NatRepr elSize)
                  -> !(NatRepr sz)
                  -> !(f (BVType (elNum * elSize)))
                  -> !(f (BVType sz))
                  -> X86PrimFn f (BVType (elNum * elSize))

  -- | Pointwise binary operation on vectors. Should not have side effects.
  --
  -- For the expression @Pointwise2 n w op vec1 vec2@:
  --
  -- * @n@ is the number of elements in the vector
  -- * @w@ is the size of each element in bits
  -- * @op@ is the binary operation to perform on the vectors
  -- * @vec1@ is the first vector
  -- * @vec2@ is the second vector
  Pointwise2 :: (1 <= elSize, 1 <= elNum) =>
                !(NatRepr elNum)
             -> !(NatRepr elSize)
             -> !AVXPointWiseOp2
             -> !(f (BVType (elNum * elSize)))
             -> !(f (BVType (elNum * elSize)))
             -> X86PrimFn f (BVType (elNum * elSize))

  {- | Extract 128 bits from a 256 bit value, as described by the
       control mask -}
  VExtractF128 ::
    !(f (BVType 256)) ->
    !Word8 ->
    X86PrimFn f (BVType 128)



instance HasRepr (X86PrimFn f) TypeRepr where
  typeRepr f =
    case f of
      EvenParity{}  -> knownRepr
      ReadLoc loc   -> typeRepr loc
      ReadFSBase    -> knownRepr
      ReadGSBase    -> knownRepr
      CPUID{}       -> knownRepr
      CMPXCHG8B{}   -> knownRepr
      RDTSC{}       -> knownRepr
      XGetBV{}      -> knownRepr
      PShufb w _ _  -> BVTypeRepr (typeRepr w)
      MemCmp{}      -> knownRepr
      RepnzScas{}   -> knownRepr
      MMXExtend{}   -> knownRepr
      X86IDiv w _ _ -> typeRepr (repValSizeMemRepr w)
      X86IRem w _ _ -> typeRepr (repValSizeMemRepr w)
      X86Div  w _ _ -> typeRepr (repValSizeMemRepr w)
      X86Rem  w _ _ -> typeRepr (repValSizeMemRepr w)
      SSE_VectorOp _ w tp _ _ -> packedType w tp
      SSE_CMPSX _ tp _ _  -> typeRepr tp
      SSE_UCOMIS _ _ _  -> knownRepr
      SSE_CVTSS2SD{} -> knownRepr
      SSE_CVTSD2SS{} -> knownRepr
      SSE_CVTSI2SX tp _ _ -> typeRepr tp
      SSE_CVTTSX2SI w _ _ -> BVTypeRepr w
      X87_Extend{} -> knownRepr
      X87_FAdd{} -> knownRepr
      X87_FSub{} -> knownRepr
      X87_FMul{} -> knownRepr
      X87_FST tp _ -> typeRepr tp
      PointwiseShiftL n w _ _ _ -> packedAVX n w
      VInsert n w _ _ _ -> packedAVX n w
      VOp1 w _ _ -> BVTypeRepr w
      VOp2 w _ _ _ -> BVTypeRepr w
      Pointwise2 n w _ _ _ -> packedAVX n w
      VExtractF128 {} -> knownRepr

packedAVX :: (1 <= n, 1 <= w) => NatRepr n -> NatRepr w ->
                                                  TypeRepr (BVType (n*w))
packedAVX n w =
  case leqMulPos n w of
    LeqProof -> BVTypeRepr (natMultiply n w)

packedType :: (1 <= n, 1 <= w) => NatRepr n -> SSE_FloatType (BVType w) -> TypeRepr (BVType (n*w))
packedType w tp =
  case leqMulPos w (typeWidth tp) of
    LeqProof -> BVTypeRepr (natMultiply w (typeWidth tp))

instance FunctorFC X86PrimFn where
  fmapFC = fmapFCDefault

instance FoldableFC X86PrimFn where
  foldMapFC = foldMapFCDefault

instance TraversableFC X86PrimFn where
  traverseFC go f =
    case f of
      EvenParity x -> EvenParity <$> go x
      ReadLoc l  -> pure (ReadLoc l)
      ReadFSBase -> pure ReadFSBase
      ReadGSBase -> pure ReadGSBase
      CPUID v    -> CPUID <$> go v
      CMPXCHG8B a ax bx cx dx  -> CMPXCHG8B <$> go a <*> go ax <*> go bx <*> go cx <*> go dx
      RDTSC      -> pure RDTSC
      XGetBV v   -> XGetBV <$> go v
      PShufb w x y -> PShufb w <$> go x <*> go y
      MemCmp sz cnt src dest rev ->
        MemCmp sz <$> go cnt <*> go src <*> go dest <*> go rev
      RepnzScas sz val buf cnt ->
        RepnzScas sz <$> go val <*> go buf <*> go cnt
      MMXExtend v -> MMXExtend <$> go v
      X86IDiv w n d -> X86IDiv w <$> go n <*> go d
      X86IRem w n d -> X86IRem w <$> go n <*> go d
      X86Div  w n d -> X86Div  w <$> go n <*> go d
      X86Rem  w n d -> X86Rem  w <$> go n <*> go d
      SSE_VectorOp op n tp x y -> SSE_VectorOp op n tp <$> go x <*> go y
      SSE_CMPSX c tp x y -> SSE_CMPSX c tp <$> go x <*> go y
      SSE_UCOMIS tp x y -> SSE_UCOMIS tp <$> go x <*> go y
      SSE_CVTSS2SD x -> SSE_CVTSS2SD <$> go x
      SSE_CVTSD2SS x -> SSE_CVTSD2SS <$> go x
      SSE_CVTSI2SX tp w  x -> SSE_CVTSI2SX  tp w <$> go x
      SSE_CVTTSX2SI w tp x -> SSE_CVTTSX2SI w tp <$> go x
      X87_Extend tp x -> X87_Extend tp <$> go x
      X87_FAdd x y -> X87_FAdd <$> go x <*> go y
      X87_FSub x y -> X87_FSub <$> go x <*> go y
      X87_FMul x y -> X87_FMul <$> go x <*> go y
      X87_FST tp x -> X87_FST tp <$> go x


      VOp1 w o x   -> VOp1 w o <$> go x
      VOp2 w o x y -> VOp2 w o <$> go x <*> go y
      PointwiseShiftL e n s x y -> PointwiseShiftL e n s <$> go x <*> go y
      Pointwise2 n w o x y -> Pointwise2 n w o <$> go x <*> go y
      VExtractF128 x i -> (`VExtractF128` i) <$> go x
      VInsert n w v e i -> (\v' e' -> VInsert n w v' e' i) <$> go v <*> go e

instance IsArchFn X86PrimFn where
  ppArchFn pp f = do
    let ppShow :: (Applicative m, Show a) => a -> m Doc
        ppShow = pure . text . show
    case f of
      EvenParity x -> sexprA "even_parity" [ pp x ]
      ReadLoc loc -> pure $ pretty loc
      ReadFSBase  -> pure $ text "fs.base"
      ReadGSBase  -> pure $ text "gs.base"
      CPUID code  -> sexprA "cpuid" [ pp code ]
      CMPXCHG8B a ax bx cx dx -> sexprA "cmpxchg8b" [ pp a, pp ax, pp bx, pp cx, pp dx ]
      RDTSC       -> pure $ text "rdtsc"
      XGetBV code -> sexprA "xgetbv" [ pp code ]
      PShufb _ x s -> sexprA "pshufb" [ pp x, pp s ]
      MemCmp sz cnt src dest rev -> sexprA "memcmp" args
        where args = [pure (pretty sz), pp cnt, pp dest, pp src, pp rev]
      RepnzScas _ val buf cnt  -> sexprA "first_byte_offset" args
        where args = [pp val, pp buf, pp cnt]
      MMXExtend e -> sexprA "mmx_extend" [ pp e ]
      X86IDiv w n d -> sexprA "idiv" [ ppShow $ typeWidth $ repValSizeMemRepr w, pp n, pp d ]
      X86IRem w n d -> sexprA "irem" [ ppShow $ typeWidth $ repValSizeMemRepr w, pp n, pp d ]
      X86Div  w n d -> sexprA "div"  [ ppShow $ typeWidth $ repValSizeMemRepr w, pp n, pp d ]
      X86Rem  w n d -> sexprA "rem"  [ ppShow $ typeWidth $ repValSizeMemRepr w, pp n, pp d ]
      SSE_VectorOp op n tp x y ->
        sexprA ("sse_" ++ sseOpName op) [ ppShow n, ppShow tp, pp x, pp y ]
      SSE_CMPSX c tp  x y -> sexprA "sse_cmpsx" [ ppShow c, ppShow tp, pp x, pp y ]
      SSE_UCOMIS  _ x y -> sexprA "ucomis" [ pp x, pp y ]
      SSE_CVTSS2SD       x -> sexprA "cvtss2sd" [ pp x ]
      SSE_CVTSD2SS       x -> sexprA "cvtsd2ss" [ pp x ]
      SSE_CVTSI2SX  tp w x -> sexprA "cvtsi2sx" [ ppShow tp, ppShow w, pp x ]
      SSE_CVTTSX2SI w tp x -> sexprA "cvttsx2si" [ ppShow w, ppShow tp, pp x ]
      X87_Extend tp x -> sexprA "x87_extend" [ ppShow tp, pp x ]
      X87_FAdd x y -> sexprA "x87_add" [ pp x, pp y ]
      X87_FSub x y -> sexprA "x87_sub" [ pp x, pp y ]
      X87_FMul x y -> sexprA "x87_mul" [ pp x, pp y ]
      X87_FST tp x -> sexprA "x86_fst" [ ppShow tp, pp x]
      VOp1 _ o x   -> sexprA (show o) [ pp x ]
      VOp2 _ o x y -> sexprA (show o) [ pp x, pp y ]
      PointwiseShiftL _ w _ x y -> sexprA "pointwiseShiftL"
                                     [ ppShow (widthVal w), pp x, pp y ]
      Pointwise2 _ w o x y -> sexprA (show o)
                                [ ppShow (widthVal w) , pp x , pp y ]
      VExtractF128 x i -> sexprA "vextractf128" [ pp x, ppShow i ]
      VInsert n w v e i -> sexprA "vinsert" [ ppShow (widthVal n)
                                            , ppShow (widthVal w)
                                            , pp v
                                            , pp e
                                            , ppShow (widthVal i)
                                            ]


-- | This returns true if evaluating the primitive function implicitly
-- changes the processor state in some way.
x86PrimFnHasSideEffects :: X86PrimFn f tp -> Bool
x86PrimFnHasSideEffects f =
  case f of
    EvenParity{} -> False
    ReadLoc{}    -> False
    ReadFSBase   -> False
    ReadGSBase   -> False
    CPUID{}      -> False
    CMPXCHG8B{}  -> True
    RDTSC        -> False
    XGetBV{}     -> False
    PShufb{}     -> False
    MemCmp{}     -> False
    RepnzScas{}  -> True
    MMXExtend{}  -> False
    X86IDiv{}    -> True -- To be conservative we treat the divide errors as side effects.
    X86IRem{}    -> True -- /\ ..
    X86Div{}     -> True -- /\ ..
    X86Rem{}     -> True -- /\ ..

    -- Each of these may throw exceptions based on floating point config flags.
    SSE_VectorOp{}  -> True
    SSE_CMPSX{}     -> True
    SSE_UCOMIS{}    -> True
    SSE_CVTSS2SD{}  -> True
    SSE_CVTSD2SS{}  -> True
    SSE_CVTSI2SX{}  -> True
    SSE_CVTTSX2SI{} -> True
    X87_FAdd{}   -> True
    X87_FSub{}   -> True
    X87_FMul{}   -> True
    X87_FST{}    -> True
    -- Extension never throws exception
    X87_Extend{}  -> False

    VOp1 {} -> False
    VOp2 {} -> False
    PointwiseShiftL {} -> False
    Pointwise2 {} -> False
    VExtractF128 {} -> False
    VInsert {} -> False

------------------------------------------------------------------------
-- X86Stmt

-- | An X86 specific statement.
data X86Stmt (v :: Type -> Kind.Type) where
  WriteLoc :: !(X86PrimLoc tp) -> !(v tp) -> X86Stmt v

  -- | Store the X87 control register in the given address.
  StoreX87Control :: !(v (BVType 64)) -> X86Stmt v

  -- | Copy a region of memory from a source buffer to a destination buffer.
  --
  -- In an expression @RepMovs bc dest src cnt dir@:
  --
  -- * @bc@ denotes the bytes to copy at a time.
  -- * @dest@ is the start of destination buffer.
  -- * @src@ is the start of source buffer.
  -- * @cnt@ is the number of values to move.
  -- * @dir@ is a flag that indicates the direction of move ('True' ==
  --   decrement, 'False' == increment) for updating the buffer
  --   pointers.
  RepMovs :: !(RepValSize w)
          -> !(v (BVType 64))
          -> !(v (BVType 64))
          -> !(v (BVType 64))
          -> !(v BoolType)
          -> X86Stmt v

  -- | Assign all elements in an array in memory a specific value.
  --
  -- In an expression @RepStos bc dest val cnt dir@:
  -- * @bc@ denotes the bytes to copy at a time.
  -- * @dest@ is the start of destination buffer.
  -- * @val@ is the value to write to.
  -- * @cnt@ is the number of values to move.
  -- * @dir@ is a flag that indicates the direction of move ('True' ==
  --   decrement, 'False' == increment) for updating the buffer
  --   pointers.
  RepStos :: !(RepValSize w)
          -> !(v (BVType 64))
             -- /\ Address to start assigning to.
          -> !(v (BVType w))
             -- /\ Value to assign
          -> !(v (BVType 64))
             -- /\ Number of values to assign
          -> !(v BoolType)
            -- /\ Direction flag
          -> X86Stmt v

  -- | Empty MMX technology State. Sets the x87 FPU tag word to empty.
  --
  -- Probably OK to use this for both EMMS FEMMS, the second being a
  -- faster version from AMD 3D now.
  EMMS :: X86Stmt v

instance FunctorF X86Stmt where
  fmapF = fmapFDefault

instance FoldableF X86Stmt where
  foldMapF = foldMapFDefault

instance TraversableF X86Stmt where
  traverseF go stmt =
    case stmt of
      WriteLoc loc v    -> WriteLoc loc <$> go v
      StoreX87Control v -> StoreX87Control <$> go v
      RepMovs bc dest src cnt dir -> RepMovs bc <$> go dest <*> go src <*> go cnt <*> go dir
      RepStos bc dest val cnt dir -> RepStos bc <$> go dest <*> go val <*> go cnt <*> go dir
      EMMS -> pure EMMS

instance IsArchStmt X86Stmt where
  ppArchStmt pp stmt =
    case stmt of
      WriteLoc loc rhs -> pretty loc <+> text ":=" <+> pp rhs
      StoreX87Control addr -> pp addr <+> text ":= x87_control"
      RepMovs bc dest src cnt dir ->
          text "repMovs" <+> parens (hcat $ punctuate comma args)
        where args = [pretty (repValSizeByteCount bc), pp dest, pp src, pp cnt, pp dir]
      RepStos bc dest val cnt dir ->
          text "repStos" <+> parens (hcat $ punctuate comma args)
        where args = [pretty (repValSizeByteCount bc), pp dest, pp val, pp cnt, pp dir]
      EMMS -> text "emms"

------------------------------------------------------------------------
-- X86_64

data X86_64

type instance ArchReg  X86_64 = X86Reg
type instance ArchFn   X86_64 = X86PrimFn
type instance ArchStmt X86_64 = X86Stmt
type instance ArchTermStmt X86_64 = X86TermStmt

-- x86 instructions can start at any byte
instance IPAlignment X86_64 where
  fromIPAligned = Just
  toIPAligned = id

rewriteX86PrimFn :: X86PrimFn (Value X86_64 src) tp
                 -> Rewriter X86_64 s src tgt (Value X86_64 tgt tp)
rewriteX86PrimFn f =
  case f of
    EvenParity (BVValue _ xv) -> do
      let go 8 r = r
          go i r = go (i+1) $! (xv `testBit` i /= r)
      pure $ BoolValue (go 0 True)
    MMXExtend e -> do
      tgtExpr <- rewriteValue e
      case tgtExpr of
        BVValue _ i -> do
          pure $ BVValue (knownNat :: NatRepr 80) $ 0xffff `shiftL` 64 .|. i
        _ -> evalRewrittenArchFn (MMXExtend tgtExpr)
    _ -> do
      evalRewrittenArchFn =<< traverseFC rewriteValue f

rewriteX86Stmt :: X86Stmt (Value X86_64 src) -> Rewriter X86_64 s src tgt ()
rewriteX86Stmt f = do
  s <- traverseF rewriteValue f
  appendRewrittenArchStmt s

rewriteX86TermStmt :: X86TermStmt src -> Rewriter X86_64 s src tgt (X86TermStmt tgt)
rewriteX86TermStmt f =
  case f of
    X86Syscall -> pure X86Syscall
    Hlt -> pure Hlt
    UD2 -> pure UD2
