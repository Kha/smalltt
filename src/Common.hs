{-# language UnboxedTuples, UnboxedSums #-}

{-|
Definitions of basic types and operations which don't depend on the types for
core syntax and runtime values. A bit random.

We use low-level bit-packed definitions for several types, and present a nicer
API with pattern synonyms.
-}

module Common (
    module Common
  , Span(..)
  , Pos(..)
  , Result(..)
  , coerce
  , Type
  , TYPE
  , RuntimeRep(..)
  , Proxy(..)
  , unpackUTF8
  , packUTF8
  , HasCallStack) where

import Prelude hiding (Monad(..), Applicative(..), IO)
import qualified Prelude as P

import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B

import Data.Bits
import Data.Flat
import Data.Kind
import Data.List
import Data.Proxy
import Data.Time.Clock
import FlatParse.Stateful (Span(..), Pos(..), Result(..), unsafeSlice, unpackUTF8, packUTF8)
import GHC.Exts
import GHC.ForeignPtr
import GHC.Stack

import qualified UIO as U
import qualified UIO

#include "deriveCanIO.h"

-- Constants
--------------------------------------------------------------------------------

-- | Maximum number of allowed local binders.
maxLocals :: Lvl
maxLocals = 64; {-# inline maxLocals #-}


-- Debug printing, toggled by "debug" cabal flag
--------------------------------------------------------------------------------

-- define DEBUG

#ifdef DEBUG
type Dbg = HasCallStack

debug :: [String] -> UIO.IO ()
debug strs = U.io $ putStrLn (intercalate " | " strs ++ " END")

debugging :: UIO.IO () -> UIO.IO ()
debugging act = act
{-# inline debugging #-}
#else
type Dbg = () :: Constraint

debug :: [String] -> UIO.IO ()
debug strs = U.pure ()
{-# inline debug #-}

debugging :: UIO.IO () -> UIO.IO ()
debugging _ = U.pure ()
{-# inline debugging #-}
#endif

debug' :: [String] -> UIO.IO ()
debug' strs = U.io $ putStrLn (intercalate " | " strs ++ " END")

debugging' :: UIO.IO () -> UIO.IO ()
debugging' act = act
{-# inline debugging' #-}

--------------------------------------------------------------------------------

type Src = B.ByteString

uf :: Dbg => a
uf = undefined
{-# noinline uf #-}

infix 2 //
-- | Strict pair construction.
(//) :: a -> b -> (a, b)
a // b = (a, b)
{-# inline (//) #-}

impossible :: Dbg => a
impossible = error "impossible"
{-# noinline impossible #-}

-- | Pointer equality.
ptrEq :: a -> a -> Bool
ptrEq !x !y = isTrue# (reallyUnsafePtrEquality# x y)
{-# inline ptrEq #-}

ctzInt :: Int -> Int
ctzInt (I# n) = I# (word2Int# (ctz# (int2Word# n)))
{-# inline ctzInt #-}

infixl 0 $$!
-- | Strict function application that associates to the left. A more convenient
--   version of `($!)`.
($$!) :: (a -> b) -> a -> b
($$!) f x = f x
{-# inline ($$!) #-}

-- Unboxed bool
--------------------------------------------------------------------------------

newtype UBool = UBool# Int deriving Eq via Int
pattern UTrue, UFalse :: UBool
pattern UTrue = UBool# 1
pattern UFalse = UBool# 0
{-# complete UTrue, UFalse #-}

infixr 3 &&#
(&&#) :: UBool -> UBool -> UBool
(&&#) (UBool# x) (UBool# y) = UBool# (x .&. y)
{-# inline (&&#) #-}

infixr 2 ||#
(||#) :: UBool -> UBool -> UBool
(||#) (UBool# x) (UBool# y) = UBool# (x .|. y)
{-# inline (||#) #-}

CAN_IO(UBool, IntRep, Int#, UBool# (I# x), CoeUBool)

instance Show UBool where
  show UTrue = "UTrue"
  show _     = "UFalse"

-- Unboxed Maybe
--------------------------------------------------------------------------------

data UMaybe a = UMaybe# (# a | (# #) #)
pattern UNothing :: UMaybe a
pattern UNothing = UMaybe# (# | (# #) #)
pattern UJust :: a -> UMaybe a
pattern UJust a <- UMaybe# (# a | #) where
  UJust !a = UMaybe# (# a | #)
{-# complete UNothing, UJust #-}

type UMaybeRepRep = SumRep [ LiftedRep, TupleRep '[]]
type UMaybeRep a  = (# a | (# #) #)
CAN_IO(UMaybe a, UMaybeRepRep, UMaybeRep a, UMaybe# x, CoeUMaybe)

uMaybe :: b -> (a -> b) -> UMaybe a -> b
uMaybe n j UNothing  = n
uMaybe n j (UJust a) = j a
{-# inline uMaybe #-}

-- | Returns 1 for `UJust`, 2 for `UNothing`.
tag :: UMaybe a -> Int
tag (UMaybe# x) = case unsafeCoerce# x :: (# Int#, () #) of
  (# t, _ #) -> I# t
{-# inline tag #-}

instance Eq a => Eq (UMaybe a) where
  UNothing == UNothing = True
  UJust a == UJust a' = a == a'
  _ == _ = False
  {-# inline (==) #-}

boxUMaybe :: UMaybe a -> Maybe a
boxUMaybe = uMaybe Nothing Just
{-# inline boxUMaybe #-}

instance Show a => Show (UMaybe a) where
  showsPrec n = showsPrec n . boxUMaybe

--------------------------------------------------------------------------------

-- | States for approximate conversion checking. See the README for more
--   details.
newtype ConvState = ConvState# Int deriving Eq via Int
pattern Rigid :: ConvState
pattern Rigid = ConvState# 0
pattern Flex :: ConvState
pattern Flex = ConvState# 1
pattern Full :: ConvState
pattern Full = ConvState# 2
{-# complete Rigid, Flex, Full #-}

instance Show ConvState where
  show Rigid = "Rigid"
  show Flex  = "Flex"
  show Full  = "Full"

--------------------------------------------------------------------------------

-- | Unfolding modes for quotation.
newtype QuoteOption = QuoteOption# Int deriving Eq via Int

-- | Unfold solved metas and top definitions.
pattern UnfoldAll :: QuoteOption
pattern UnfoldAll = QuoteOption# 0

-- | Unfold solved metas only.
pattern UnfoldMetas :: QuoteOption
pattern UnfoldMetas = QuoteOption# 1

-- | Don't unfold any top entry.
pattern UnfoldNone :: QuoteOption
pattern UnfoldNone = QuoteOption# 2
{-# complete UnfoldAll, UnfoldMetas, UnfoldNone #-}

instance Show QuoteOption where
  show UnfoldAll   = "UnfoldAll"
  show UnfoldMetas = "UnfoldMetas"
  show UnfoldNone  = "UnfoldNone"

-- Icitness
--------------------------------------------------------------------------------

newtype Icit = Icit# Int deriving Eq
pattern Impl :: Icit
pattern Impl = Icit# (-1)
pattern Expl :: Icit
pattern Expl = Icit# (-2)
{-# complete Impl, Expl #-}

CAN_IO(Icit, IntRep, Int#, Icit# (I# x), CoeIcit)

instance Show Icit where
  show Impl = "Impl"
  show Expl = "Expl"

icit :: Icit -> a -> a -> a
icit Impl x y = x
icit Expl x y = y
{-# inline icit #-}


-- De Bruijn indices and levels
--------------------------------------------------------------------------------

newtype Ix = Ix {unIx :: Int}
  deriving (Eq, Ord, Show, Num, Enum, Bits) via Int

newtype Lvl = Lvl {unLvl :: Int}
  deriving (Eq, Ord, Show, Num, Enum, Bits, Flat) via Int

CAN_IO(Lvl, IntRep, Int#, Lvl (I# x), CoeLvl)

newtype MetaVar = MkMetaVar Int
  deriving (Eq, Ord, Num, Flat) via Int

instance Show MetaVar where
  show (MkMetaVar x) = '?':show x

CAN_IO(MetaVar, IntRep, Int#, MkMetaVar (I# x), CoeMetaVar)

lvlToIx :: Lvl -> Lvl -> Ix
lvlToIx (Lvl envl) (Lvl x) = Ix (envl - x - 1)
{-# inline lvlToIx #-}


-- Names
--------------------------------------------------------------------------------

-- data Name = NEmpty | NX | NSpan Span
data Name = Name# Int Int

unName# :: Name -> (# (# #) | (# #) | Span #)
unName# (Name# (-1) _) = (# (# #) | | #)
unName# (Name# (-2) _) = (# | (# #) | #)
unName# (Name# x y   ) = (# | | Span (Pos x) (Pos y) #)
{-# inline unName# #-}

-- | An unused (underscore) binder in source syntax becomes
--   an `Empty` `Name`.
pattern NEmpty :: Name
pattern NEmpty <- (unName# -> (# (# #) | | #))  where
  NEmpty = Name# (-1) 0

-- | `NX` is a generic fresh name. It will be printed as "x", usually
--   un-shadowed as "xN" with "N" a number.
pattern NX :: Name
pattern NX <- (unName# -> (# | (# #) | #)) where
  NX = Name# (-2) 0

-- | `NSpan` is a span pointing into the source `ByteString`.
pattern NSpan :: Span -> Name
pattern NSpan sp <- (unName# -> (# | | sp #)) where
  NSpan (Span (Pos x) (Pos y)) = Name# x y
{-# complete NX, NEmpty, NSpan #-}

instance Show Name where
  showsPrec d NEmpty    = ('_':)
  showsPrec d NX        = ('x':)
  showsPrec d (NSpan x) = showsPrec d x

showSpan :: Src -> Span -> String
showSpan src s = unpackUTF8 $ unsafeSlice src s

showName :: Src -> Name -> String
showName src = \case
  NEmpty  -> "_"
  NX      -> "x"
  NSpan s -> showSpan src s


-- A Name and an Icit packed to two words
--------------------------------------------------------------------------------

-- data NameIcit = NI Name Icit
data NameIcit = NameIcit# Int Int

pattern NI :: Name -> Icit -> NameIcit
pattern NI n i <- ((\case NameIcit# x y -> (Name# (unsafeShiftR x 1) y, Icit# ((x .&. 1) - 2)))
                    -> (n, i)) where
  NI (Name# x y) (Icit# i) = NameIcit# (unsafeShiftL x 1 .|. (i + 2)) y
{-# complete NI #-}

instance Show NameIcit where
  showsPrec d (NI n i) =
    showParen (d > 10) (("NI "++). showsPrec 11 n . (' ':) . showsPrec 11 i)


-- Span equality
--------------------------------------------------------------------------------

#if MIN_VERSION_base(4,16,0)
indexWord8OffAddr s x = word8ToWord# (indexWord8OffAddr# s x)
#else
indexWord8OffAddr  = indexWord8OffAddr#
#endif
{-# inline indexWord8OffAddr #-}


-- | Read between 1 and 7 bytes from an address.
indexPartialWord# :: Int# -> Addr# -> Word#
indexPartialWord# len addr =
  case indexWordOffAddr# addr 0# of
    w -> case uncheckedIShiftL# (8# -# len) 3# of
      sh -> case uncheckedShiftL# w sh of
        w -> uncheckedShiftRL# w sh
{-# inline indexPartialWord# #-}

-- little endian!
indexPartialWord'# :: Int# -> Addr# -> Word#
indexPartialWord'# = go 0## 0# where
  go acc shift 0# _  = acc
  go acc shift l ptr =
    go (or# acc (uncheckedShiftL# (indexWord8OffAddr ptr 0#) shift))
       (shift +# 8#)
       (l -# 1#)
       (plusAddr# ptr 1#)

eqSpanGo :: Addr# -> Addr# -> Int# -> Int#
eqSpanGo p p' len = case len <# 8# of
  1# -> case len of
    0# -> 1#
    _  -> eqWord# (indexPartialWord# len p) (indexPartialWord# len p')
  _  -> case eqWord# (indexWordOffAddr# p 0#) (indexWordOffAddr# p' 0#) of
    1# -> eqSpanGo (plusAddr# p 8#) (plusAddr# p' 8#) (len -# 8#)
    _  -> 0#

eqSpanGo' :: Addr# -> Addr# -> Int# -> Int#
eqSpanGo' p p' len = case len <# 8# of
  1# -> case len of
    0# -> 1#
    _  -> case eqWord# (indexWord8OffAddr p 0#) (indexWord8OffAddr p' 0#) of
      1# -> eqSpanGo' (plusAddr# p 1#) (plusAddr# p' 1#) (len -# 1#)
      _  -> 0#
  _  -> case eqWord# (indexWordOffAddr# p 0#) (indexWordOffAddr# p' 0#) of
    1# -> eqSpanGo' (plusAddr# p 8#) (plusAddr# p' 8#) (len -# 8#)
    _  -> 0#

-- | Compare spans with the same base address.
eqSpan# :: Addr# -> Span -> Span -> Int#
eqSpan# _   s s' | s == s' = 1#
eqSpan# eob (Span (Pos (I# x)) (Pos (I# y))) (Span (Pos (I# x')) (Pos (I# y'))) = let
  len  = x -# y
  len' = x' -# y'
  in case len ==# len' of
    1# -> let
      start  = plusAddr# eob (negateInt# x )
      start' = plusAddr# eob (negateInt# x')
      in case orI# (y <# 8#) (y' <# 8#) of
        1# -> eqSpanGo' start start' len
        _  -> eqSpanGo  start start' len
    _  -> 0#
{-# inline eqSpan# #-}

-- | Compare spans with different base addresses.
eqBasedSpan# :: Addr# -> Span -> Addr# -> Span -> Int#
eqBasedSpan# eob  (Span (Pos (I# x))  (Pos (I# y)))
         eob' (Span (Pos (I# x')) (Pos (I# y'))) = let
  len  = x -# y
  len' = x' -# y'
  in case len ==# len' of
    1# -> let
      go p p' l = case l of
        0# -> 1#
        _  -> case eqWord# (indexWord8OffAddr p 0#) (indexWord8OffAddr p' 0#) of
          1# -> go (plusAddr# p 1#) (plusAddr# p' 1#) (l -# 1#)
          _  -> 0#
      in go (plusAddr# eob (negateInt# x))
            (plusAddr# eob' (negateInt# x')) len
    _  -> 0#

eqSpan :: Src -> Span -> Span -> Bool
eqSpan (B.BS (ForeignPtr base _) (I# len)) s s' =
  isTrue# (eqSpan# (plusAddr# base len) s s')
{-# inline eqSpan #-}


-- Timing
--------------------------------------------------------------------------------

-- | Time an IO computation. Result is forced to whnf.
timed :: P.IO a -> P.IO (a, NominalDiffTime)
timed a = do
  t1  <- getCurrentTime
  res <- a
  t2  <- getCurrentTime
  let diff = diffUTCTime t2 t1
  P.pure (res, diff)
{-# inline timed #-}

-- | Time a lazy pure value. Result is forced to whnf.
timedPure :: a -> P.IO (a, NominalDiffTime)
timedPure ~a = do
  t1  <- getCurrentTime
  let res = a
  t2  <- getCurrentTime
  let diff = diffUTCTime t2 t1
  P.pure (res, diff)
{-# noinline timedPure #-}

-- | Time a lazy pure value. Result is forced to whnf.
timedPure_ :: a -> P.IO NominalDiffTime
timedPure_ ~a = do
  t1  <- getCurrentTime
  let res = a
  t2  <- getCurrentTime
  let diff = diffUTCTime t2 t1
  P.pure diff
{-# noinline timedPure_ #-}
