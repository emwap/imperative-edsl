{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Deep embedding of imperative programs. The embedding is parameterized on the expression
-- language.

module Language.Embedded.Imperative where
  -- TODO Should export PrintfArg



import Data.Array.IO
import Data.IORef
import Data.Typeable
import qualified System.IO as IO
import Text.Printf (PrintfArg)
import qualified Text.Printf as Printf

import Control.Monad (when)
import Control.Monad.Operational.Compositional
import Data.Constraint
import Language.C.Quote.C
import qualified Language.C.Syntax as C

import Language.C.Monad



----------------------------------------------------------------------------------------------------
-- * Interpretation of expressions
----------------------------------------------------------------------------------------------------

-- | Constraint on the types of variables in a given expression language
type family VarPred (exp :: * -> *) :: * -> Constraint

-- | General interface for evaluating expressions
class EvalExp exp
  where
    -- | Literal expressions
    litExp  :: VarPred exp a => a -> exp a

    -- | Evaluation of (closed) expressions
    evalExp :: exp a -> a

-- | General interface for compiling expressions
class CompExp exp
  where
    -- | Variable expressions
    varExp  :: VarPred exp a => VarId -> exp a

    -- | Compilation of expressions
    compExp :: (MonadC m) => exp a -> m C.Exp

-- | Variable identifier
type VarId = String

-- | Universal predicate
class    Any a
instance Any a

-- | Predicate conjunction
class    (p1 a, p2 a) => (p1 :/\: p2) a
instance (p1 a, p2 a) => (p1 :/\: p2) a



----------------------------------------------------------------------------------------------------
-- * Composing instruction sets
----------------------------------------------------------------------------------------------------

-- | Tag an instruction with a predicate and expression. This is needed to avoid types like
-- @(`RefCMD` pred exp `:<:` i) => `Program` i ()@. Here it is not possible to constrain @pred@ and
-- @exp@ by constraining @i@, so the instrance search will always fail. The solution is to change
-- the type to @(`RefCMD` pred exp `:<:` i) => `Program` (`Tag` pred exp i) ()@.
newtype Tag (pred :: * -> Constraint) (exp :: * -> *) instr (prog :: * -> *) a =
    Tag {unTag :: instr prog a}
  deriving (Typeable, Functor)

instance (i :<: j) => i :<: Tag pred exp j
  where
    inj = Tag . inj

instance MapInstr i => MapInstr (Tag pred exp i)
  where
    imap f = Tag . imap f . unTag

instance Interp i m => Interp (Tag pred exp i) m
  where
    interp = interp . unTag

-- | Create a program from an instruction in a tagged instruction set
singlePE :: (i pred exp :<: instr) =>
    i pred exp (ProgramT (Tag pred exp instr) m) a -> ProgramT (Tag pred exp instr) m a
singlePE = singleton . Tag . inj

-- | Create a program from an instruction in a tagged instruction set
singleE :: (i exp :<: instr) =>
    i exp (ProgramT (Tag pred exp instr) m) a -> ProgramT (Tag pred exp instr) m a
singleE = singleton . Tag . inj



----------------------------------------------------------------------------------------------------
-- * Commands
----------------------------------------------------------------------------------------------------

data Ref a
    = RefComp String
    | RefEval (IORef a)
  deriving Typeable

-- | Commands for mutable references
data RefCMD p exp (prog :: * -> *) a
  where
    NewRef          :: p a => RefCMD p exp prog (Ref a)
    InitRef         :: p a => exp a -> RefCMD p exp prog (Ref a)
    GetRef          :: p a => Ref a -> RefCMD p exp prog (exp a)
    SetRef          ::        Ref a -> exp a -> RefCMD p exp prog ()
    UnsafeFreezeRef :: p a => Ref a -> RefCMD p exp prog (exp a)
  deriving Typeable

instance MapInstr (RefCMD p exp)
  where
    imap f NewRef              = NewRef
    imap f (InitRef a)         = InitRef a
    imap f (GetRef r)          = GetRef r
    imap f (SetRef r a)        = SetRef r a
    imap f (UnsafeFreezeRef r) = UnsafeFreezeRef r

data Arr a
    = ArrComp String
    | ArrEval (IOArray Int a)
  deriving Typeable

-- | Commands for mutable arrays
data ArrCMD p exp (prog :: * -> *) a
  where
    NewArr :: (p a, Integral n) => exp n -> exp a -> ArrCMD p exp prog (Arr a)
    GetArr :: (p a, Integral n) => exp n -> Arr a -> ArrCMD p exp prog (exp a)
    SetArr :: Integral n        => exp n -> exp a -> Arr a -> ArrCMD p exp prog ()
  deriving Typeable

instance MapInstr (ArrCMD p exp)
  where
    imap f (NewArr n a)     = NewArr n a
    imap f (GetArr i arr)   = GetArr i arr
    imap f (SetArr i a arr) = SetArr i a arr

data ControlCMD exp prog a
  where
    If    :: exp Bool -> prog () -> prog () -> ControlCMD exp prog ()
    While :: prog (exp Bool) -> prog () -> ControlCMD exp prog ()
    Break :: ControlCMD exp prog ()

instance MapInstr (ControlCMD exp)
  where
    imap g (If c t f)        = If c (g t) (g f)
    imap g (While cont body) = While (g cont) (g body)
    imap g Break             = Break

data Handle
    = HandleComp String
    | HandleEval IO.Handle
  deriving Typeable

data FileCMD exp (prog :: * -> *) a
  where
    Open  :: FilePath            -> FileCMD exp prog Handle -- todo: allow specifying read/write mode
    Close :: Handle              -> FileCMD exp prog ()
    Put   :: Handle -> exp Float -> FileCMD exp prog ()
    Get   :: Handle              -> FileCMD exp prog (exp Float) -- todo: generalize to arbitrary types
    Eof   :: Handle              -> FileCMD exp prog (exp Bool)

instance MapInstr (FileCMD exp)
  where
    imap f (Open file) = Open file
    imap f (Close hdl) = Close hdl
    imap f (Put hdl a) = Put hdl a
    imap f (Get hdl)   = Get hdl
    imap f (Eof hdl)   = Eof hdl

data ConsoleCMD exp (prog :: * -> *) a
  where
    Printf :: PrintfArg a => String -> exp a -> ConsoleCMD exp prog ()

instance MapInstr (ConsoleCMD exp)
  where
    imap f (Printf form a) = Printf form a

data TimeCMD exp (prog :: * -> *) a
  where
    GetTime :: TimeCMD exp prog (exp Double)

instance MapInstr (TimeCMD exp)
  where
    imap f GetTime = GetTime



----------------------------------------------------------------------------------------------------
-- * Running commands
----------------------------------------------------------------------------------------------------

runRefCMD :: EvalExp exp => RefCMD (VarPred exp) exp prog a -> IO a
runRefCMD (InitRef a)                   = fmap RefEval $ newIORef $ evalExp a
runRefCMD NewRef                        = fmap RefEval $ newIORef (error "Reading uninitialized reference")
runRefCMD (GetRef (RefEval r))          = fmap litExp  $ readIORef r
runRefCMD (SetRef (RefEval r) a)        = writeIORef r $ evalExp a
runRefCMD (UnsafeFreezeRef (RefEval r)) = fmap litExp  $ readIORef r

runArrCMD :: EvalExp exp => ArrCMD (VarPred exp) exp prog a -> IO a
runArrCMD (NewArr n a)               = fmap ArrEval $ newArray (0, fromIntegral (evalExp n) - 1) (evalExp a)
runArrCMD (GetArr i (ArrEval arr))   = fmap litExp $ readArray arr (fromIntegral (evalExp i))
runArrCMD (SetArr i a (ArrEval arr)) = writeArray arr (fromIntegral (evalExp i)) (evalExp a)

runControlCMD :: EvalExp exp => ControlCMD exp IO a -> IO a
runControlCMD (If c t f)        = if evalExp c then t else f
runControlCMD (While cont body) = loop
  where loop = do
          c <- cont
          when (evalExp c) $ body >> loop
runControlCMD Break = error "runControlCMD not implemented for Break"

readWord :: IO.Handle -> IO String
readWord h = do
    eof <- IO.hIsEOF h
    if eof
    then return ""
    else do
      c  <- IO.hGetChar h
      if c == ' '
      then return ""
      else do
        cs <- readWord h
        return (c:cs)

runFileCMD :: (EvalExp exp, VarPred exp Bool, VarPred exp Float) => FileCMD exp IO a -> IO a
runFileCMD (Open path)            = fmap HandleEval $ IO.openFile path IO.ReadWriteMode
runFileCMD (Close (HandleEval h)) = IO.hClose h
runFileCMD (Put (HandleEval h) a) = IO.hPrint h (evalExp a)
runFileCMD (Get (HandleEval h))   = do
    w <- readWord h
    case reads w of
        [(f,"")] -> return $ litExp f
        _        -> error $ "runFileCMD: Get: no parse (input " ++ show w ++ ")"
runFileCMD (Eof (HandleEval h)) = fmap litExp $ IO.hIsEOF h

runConsoleCMD :: EvalExp exp => ConsoleCMD exp IO a -> IO a
runConsoleCMD (Printf format a) = Printf.printf format (evalExp a)

runTimeCMD :: EvalExp exp => TimeCMD exp IO a -> IO a
runTimeCMD GetTime | False = undefined

instance (EvalExp exp, pred ~ VarPred exp)                  => Interp (RefCMD pred exp) IO where interp = runRefCMD
instance (EvalExp exp, pred ~ VarPred exp)                  => Interp (ArrCMD pred exp) IO where interp = runArrCMD
instance EvalExp exp                                        => Interp (ControlCMD exp)  IO where interp = runControlCMD
instance (EvalExp exp, VarPred exp Bool, VarPred exp Float) => Interp (FileCMD exp)     IO where interp = runFileCMD
instance EvalExp exp                                        => Interp (ConsoleCMD exp)  IO where interp = runConsoleCMD
instance EvalExp exp                                        => Interp (TimeCMD exp)     IO where interp = runTimeCMD



----------------------------------------------------------------------------------------------------
-- * User interface
----------------------------------------------------------------------------------------------------

-- | Create an uninitialized reference
newRef :: (pred a, RefCMD pred exp :<: instr) => ProgramT (Tag pred exp instr) m (Ref a)
newRef = singlePE NewRef

-- | Create an initialized reference
initRef :: (pred a, RefCMD pred exp :<: instr) => exp a -> ProgramT (Tag pred exp instr) m (Ref a)
initRef = singlePE . InitRef

-- | Get the contents of a reference
getRef :: (pred a, RefCMD pred exp :<: instr) => Ref a -> ProgramT (Tag pred exp instr) m (exp a)
getRef = singlePE . GetRef

-- | Set the contents of a reference
setRef :: (pred a, RefCMD pred exp :<: instr) =>
    Ref a -> exp a -> ProgramT (Tag pred exp instr) m ()
setRef r = singlePE . SetRef r

-- | Modify the contents of reference
modifyRef :: (pred a, RefCMD pred exp :<: instr, Monad m) =>
    Ref a -> (exp a -> exp a) -> ProgramT (Tag pred exp instr) m ()
modifyRef r f = getRef r >>= setRef r . f

-- | Freeze the contents of reference (only safe if the reference is never accessed again)
unsafeFreezeRef :: (pred a, RefCMD pred exp :<: instr) =>
    Ref a -> ProgramT (Tag pred exp instr) m (exp a)
unsafeFreezeRef = singlePE . UnsafeFreezeRef

-- | Create an uninitialized an array
newArr :: (pred a, ArrCMD pred exp :<: instr) =>
    exp Int -> exp a -> ProgramT (Tag pred exp instr) m (Arr a)
newArr n a = singlePE $ NewArr n a

-- | Set the contents of an array
getArr :: (pred a, ArrCMD pred exp :<: instr) =>
    exp Int -> Arr a -> ProgramT (Tag pred exp instr) m (exp a)
getArr i arr = singlePE (GetArr i arr)

-- | Set the contents of an array
setArr :: (pred a, ArrCMD pred exp :<: instr) =>
    exp Int -> exp a -> Arr a -> ProgramT (Tag pred exp instr) m ()
setArr i a arr = singlePE (SetArr i a arr)

iff :: (ControlCMD exp :<: instr)
    => exp Bool
    -> ProgramT (Tag pred exp instr) m ()
    -> ProgramT (Tag pred exp instr) m ()
    -> ProgramT (Tag pred exp instr) m ()
iff b t f = singleE $ If b t f

while :: (ControlCMD exp :<: instr)
    => ProgramT (Tag pred exp instr) m (exp Bool)
    -> ProgramT (Tag pred exp instr) m ()
    -> ProgramT (Tag pred exp instr) m ()
while b t = singleE $ While b t

break :: (ControlCMD exp :<: instr) => ProgramT (Tag pred exp instr) m ()
break = singleE Break

open :: (FileCMD exp :<: instr) => FilePath -> ProgramT (Tag pred exp instr) m Handle
open = singleE . Open

close :: (FileCMD exp :<: instr) => Handle -> ProgramT (Tag pred exp instr) m ()
close = singleE . Close

fput :: (FileCMD exp :<: instr) => Handle -> exp Float -> ProgramT (Tag pred exp instr) m ()
fput hdl = singleE . Put hdl

fget :: (FileCMD exp :<: instr) => Handle -> ProgramT (Tag pred exp instr) m (exp Float)
fget = singleE . Get

feof :: (FileCMD exp :<: instr) => Handle -> ProgramT (Tag pred exp instr) m (exp Bool)
feof = singleE . Eof

printf :: (PrintfArg a, ConsoleCMD exp :<: instr) =>
    String -> exp a -> ProgramT (Tag pred exp instr) m ()
printf format = singleE . Printf format

getTime :: (TimeCMD exp :<: instr) => ProgramT (Tag pred exp instr) m (exp Double)
getTime = singleE GetTime

