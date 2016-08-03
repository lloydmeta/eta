{-# LANGUAGE OverloadedStrings #-}
module GHCVM.CodeGen.Layout where

import GHCVM.Types.Type
import GHCVM.Main.DynFlags
import GHCVM.StgSyn.StgSyn
import GHCVM.BasicTypes.Id
import Codec.JVM
import GHCVM.Util
import GHCVM.CodeGen.Monad
import GHCVM.CodeGen.Types
import GHCVM.CodeGen.ArgRep
import GHCVM.CodeGen.Rts
import GHCVM.CodeGen.Env
import GHCVM.Primitive

import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Foldable (fold)

emitReturn :: [CgLoc] -> CodeGen ()
emitReturn results = do
  sequel <- getSequel
  emit $
    case sequel of
      Return         -> mkReturnExit results
      AssignTo slots -> multiAssign slots (map loadLoc results)

emitAssign :: CgLoc -> Code -> CodeGen ()
emitAssign cgLoc code = emit $ storeLoc cgLoc code

-- TODO: Verify that this is valid in all cases,
--       otherwise fall back on the strongly connected components
--       algorithm a la GHC
multiAssign :: [CgLoc] -> [Code] -> Code
multiAssign locs codes = fold $ zipWith storeLoc locs codes
-- multiAssign [] []       = mempty
-- multiAssign [loc] [rhs] = storeLoc loc rhs
-- multiAssign _ _         = error "multiAssign for more than one location"

-- TODO: Beautify this code
-- TODO: There are a lot of bangs in this function. Verify that they do
--       indeed help.
mkCallEntry :: Int -> [NonVoid Id] -> ([(NonVoid Id, CgLoc)], Code, Int)
mkCallEntry nStart nvArgs = (zip nvArgs locs, code, n)
  where fts' = map ( expectJust "mkCallEntry"
                   . repFieldType_maybe
                   . idType ) args'
        args' = map unsafeStripNV nvArgs
        argReps' = map idJArgRep args'
        (!code, !locs, !n) = loadArgs nStart mempty [] args' fts' argReps' 2 1 1 1 1 1
        loadArgs !n !code !locs (arg:args) (ft:fts) (argRep:argReps)
                 !r !i !l !f !d !o =
          case argRep of
            P -> loadRec (context r) (r + 1) i l f d o
            N -> loadRec (context i <> gconv jint ft) r (i + 1) l f d o
            L -> loadRec (context l) r i (l + 1) f d o
            F -> loadRec (context f) r i l (f + 1) d o
            D -> loadRec (context d) r i l f (d + 1) o
            O -> loadRec (context o) r i l f d (o + 1)
            _ -> error "contextLoad: V"
          where context = contextLoad ft argRep
                loadRec nextCode =
                  loadArgs (n + ftSize) (code <> nextCode <> gstore ft n)
                           (loc:locs) args fts argReps
                ftSize = fieldSize ft
                loc = LocLocal (argRep == P) ft n
        loadArgs !n !code !locs _ _ _ _ _ _ _ _ _ = (code, reverse locs, n)

mkCallExit :: Bool -> [(JArgRep, Maybe FieldType, Maybe Code)] -> Code
mkCallExit slow args' = storeArgs mempty args' rStart 1 1 1 1 1
  where rStart = if slow then 1 else 2
        storeArgs !code ((argRep, ft', code'):args) !r !i !l !f !d !o =
          case argRep of
            P -> storeRec (context r) (r + 1) i l f d o
            N -> storeRec (context i) r (i + 1) l f d o
            L -> storeRec (context l) r i (l + 1) f d o
            F -> storeRec (context f) r i l (f + 1) d o
            D -> storeRec (context d) r i l f (d + 1) o
            O -> storeRec (context o) r i l f d (o + 1)
            V -> storeArgs code args r i l f d o
          where ft = expectJust "mkCallExit:ft" ft'
                loadCode = expectJust "mkCallExit:loadCode" code'
                context = contextStore ft argRep loadCode
                storeRec nextCode =
                  storeArgs (code <> nextCode) args
        storeArgs !code _ _ _ _ _ _ _ = code

mkReturnEntry :: [CgLoc] -> Code
mkReturnEntry cgLocs' = loadVals mempty cgLocs' 1 1 1 1 1 1
  where loadVals !code (cgLoc:cgLocs) !r !i !l !f !d !o =
          case argRep of
            P -> loadRec (context r) (r + 1) i l f d o
            N -> loadRec (context i) r (i + 1) l f d o
            L -> loadRec (context l) r i (l + 1) f d o
            F -> loadRec (context f) r i l (f + 1) d o
            D -> loadRec (context d) r i l f (d + 1) o
            O -> loadRec (context o) r i l f d (o + 1)
            _ -> error "contextLoad: V"
          where ft = locFt cgLoc
                argRep = locJArgRep cgLoc
                context = contextLoad ft argRep
                loadRec nextCode =
                  loadVals (code <> storeLoc cgLoc nextCode) cgLocs
        loadVals !code _ _ _ _ _ _ _ = code

mkReturnExit :: [CgLoc] -> Code
mkReturnExit cgLocs' = storeVals mempty cgLocs' 1 1 1 1 1 1
  where storeVals !code (cgLoc:cgLocs) !r !i !l !f !d !o =
          case argRep of
            P -> storeRec (context r) (r + 1) i l f d o
            N -> storeRec (context i) r (i + 1) l f d o
            L -> storeRec (context l) r i (l + 1) f d o
            F -> storeRec (context f) r i l (f + 1) d o
            D -> storeRec (context d) r i l f (d + 1) o
            O -> storeRec (context o) r i l f d (o + 1)
            _ -> error "contextLoad: V"
          where ft = locFt cgLoc
                loadCode = loadLoc cgLoc
                argRep = locJArgRep cgLoc
                context = contextStore ft argRep loadCode
                storeRec nextCode =
                  storeVals (code <> nextCode) cgLocs
        storeVals !code _ _ _ _ _ _ _ = code

slowCall :: CgLoc -> [StgArg] -> CodeGen ()
slowCall fun args = do
  dflags <- getDynFlags
  argFtCodes <- getFtsLoadCode args
  let (apPat, arity, fts) = slowCallPattern $ map (\(a,_,_) -> a) argFtCodes
      slowCode = directCall' True (mkApFast apPat) arity
                             ((P, Just ft, Just code):argFtCodes)
  if n > arity && optLevel dflags >= 2 then do
    -- TODO: Implement optimization
    --       effectively an evaluation test + fast call
    emit slowCode
  else
    emit slowCode
  where n = length args
        ft = locFt fun
        code = loadLoc fun

directCall :: Bool -> Code -> RepArity -> [StgArg] -> CodeGen ()
directCall slow entryCode arity args = do
  argFtCodes <- getFtsLoadCode args
  emit $ directCall' slow entryCode arity argFtCodes

directCall' :: Bool -> Code -> RepArity -> [(JArgRep, Maybe FieldType, Maybe Code)] -> Code
directCall' slow entryCode arity args =
     stackLoadCode
  <> mkCallExit slow callArgs
  <> entryCode
  where (callArgs, restArgs) = splitAt realArity args
        realArity = if slow then arity + 1 else arity
        stackFrames = slowArgFrames restArgs
        stackFramesLoad = map (\code -> dup tsoType
                                     <> code
                                     <> spPushMethod)
                          stackFrames
        stackLoadCode = if null stackFrames then mempty
                        else    loadContext
                             <> currentTSOField
                             <> fold stackFramesLoad
                             <> pop tsoType

slowArgFrames :: [(JArgRep, Maybe FieldType, Maybe Code)] -> [Code]
slowArgFrames [] = []
slowArgFrames args = thisFrame : slowArgFrames restArgs
  where (argPat, n, fts) = slowCallPattern $ map (\(a,_,_) -> a) args
        (callArgs, restArgs) = splitAt n args
        thisFrame = genSlowFrame argPat fts callArgs

genSlowFrame :: Text -> [FieldType] -> [(JArgRep, Maybe FieldType, Maybe Code)] -> Code
genSlowFrame patText fts args =
     new ft
  <> dup ft
  <> fold loadCodes
  <> invokespecial (mkMethodRef patClass "<init>" fts void)
  where patClass = apply $ argPatToFrame patText
        loadCodes = mapMaybe (\(_, _, a) -> a) args
        ft = obj patClass

getFtsLoadCode :: [StgArg] -> CodeGen [(JArgRep, Maybe FieldType, Maybe Code)]
getFtsLoadCode = mapM getFtAmode
  where getFtAmode arg
          | Nothing <- ft = return (V, Nothing, Nothing)
          | otherwise = do code <- getArgLoadCode (NonVoid arg)
                           return (rep, ft, Just code)
          where ty = stgArgType arg
                ft = repFieldType_maybe ty
                rep = typeJArgRep ty

newUnboxedTupleLocs :: Type -> CodeGen [CgLoc]
newUnboxedTupleLocs resType = getSequel >>= chooseLocs
  where chooseLocs (AssignTo regs) = return regs
        chooseLocs _               = mapM (\(cl, ft) -> newTemp cl ft) reps
        UbxTupleRep tyArgs         = repType resType
        reps = [ (isPtrJRep rep, primRepFieldType rep)
               | ty <- tyArgs
               , let rep           = typeJPrimRep ty
               , not (isVoidJRep rep) ]
