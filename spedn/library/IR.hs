module IR where

import           Control.Monad.State
import           Control.Monad.Writer
import           Data.List
import           Data.Maybe
import           Data.Word

import           Syntax

data OpCode
    = OpGet Int
    | OpPick Int
    | OpRoll Int
    | OpCall Name
    | OpVerify
    | OpPush Name
    | OpPushBool Bool
    | OpPushNum Int
    | OpPushBin [Word8]
    | OpIf
    | OpElse
    | OpEndIf
    | OpDrop
    deriving (Show)

type IR = [OpCode]
type Stack = [Name]
type Compiler = StateT Stack (Writer IR) ()

emit :: [OpCode] -> Compiler
emit = tell

pushM :: Name -> Compiler
pushM name = do
    stack <- get
    put $ name : stack

popM :: Compiler
popM = do
    stack <- get
    put $ tail stack

from :: Name -> Stack -> Int
from name stack = fromJust (name `elemIndex` stack)

emitPickM :: Name -> Compiler
emitPickM name = do
    stack <- get
    emit [OpPick $ name `from` stack]
    pushM $ "$" ++ name

contractCompiler :: Contract a -> Compiler
contractCompiler (Contract _ cps cs _) = do
    mapM_ (\n -> emit [OpPush n]) $ nameof <$> cps
    if length cs == 1
    then singleChallengeCompiler cps (head cs)
    else challengesCompiler cps cs


singleChallengeCompiler :: [Param a] -> Challenge a -> Compiler
singleChallengeCompiler cps (Challenge _ ps s _) = do
    mapM_ pushM $ nameof <$> ps
    mapM_ pushM $ nameof <$> cps
    stmtCompiler s

challengesCompiler :: [Param a] -> [Challenge a] -> Compiler
challengesCompiler cps cs = do
    let cases = length cs
    mapM_ (\(c, n) -> nthChallengeCompiler cps c n cases) (zip cs [1..])
    replicateM_ cases $ emit [OpEndIf]

nthChallengeCompiler :: [Param a] -> Challenge a -> Int -> Int -> Compiler
nthChallengeCompiler cps (Challenge _ ps s _) num total = do
    mapM_ pushM $ nameof <$> ps
    pushM "$case"
    mapM_ pushM $ nameof <$> cps
    emitPickM "$case"
    emit [OpPushNum num, OpCall "Eq", OpIf]
    stmtCompiler s
    when (num < total) (emit [OpElse])

nameof :: Param a -> Name
nameof (Param _ n _) = n

stmtCompiler :: Statement a -> Compiler
stmtCompiler (Assign _ name expr _) = do
    exprCompiler expr
    popM
    pushM name
stmtCompiler (SplitAssign _ (l, r) expr _) = do
    exprCompiler expr
    popM
    popM
    pushM l
    pushM r
stmtCompiler (Verify expr _) = do
    exprCompiler expr
    popM
    emit [OpVerify]
stmtCompiler (If cond t f _) = do
    exprCompiler cond
    emit [OpIf]
    stmtCompiler t
    case f of
        Just fl -> do
            emit [OpElse]
            stmtCompiler fl
        Nothing -> return ()
    emit [OpEndIf]
stmtCompiler (Block ss _) = do
    stack <- get
    mapM_ stmtCompiler ss
    stack' <- get
    let diff = length stack' - length stack
    replicateM_ diff popM

exprCompiler :: Expr a -> Compiler
exprCompiler (BoolConst val _) = emit [OpPushBool val] >> pushM "$const"
exprCompiler (NumConst val _) = emit [OpPushNum val] >> pushM "$const"
exprCompiler (BinConst val _) = emit [OpPushBin val] >> pushM "$const"
exprCompiler (Var name _) = emitPickM name
exprCompiler (UnaryExpr op e _) = do
    exprCompiler e
    emit [OpCall $ show op]
    popM
    pushM "$tmp"
exprCompiler (BinaryExpr op l r _) = do
    exprCompiler l
    exprCompiler r
    emit [OpCall $ show op]
    popM
    popM
    pushM "$tmp"
    when (op == Split) (pushM "$tmp")
exprCompiler (TernaryExpr cond t f _) = do
    exprCompiler cond
    popM
    emit [OpIf]
    exprCompiler t
    popM
    emit [OpElse]
    exprCompiler f
    popM
    emit [OpEndIf]
    pushM "$tmp"
exprCompiler (Call name args _) = do
    mapM_ exprCompiler args
    emit [OpCall name]
    replicateM_ (length args) popM
    pushM "$tmp"