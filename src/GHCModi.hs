{-# LANGUAGE DeriveDataTypeable #-}

-- Commands:
--  check <file>
--  find <symbol>
--  info <file> <expr>
--  type <file> <line> <column>
--  lint [hlint options] <file>
--     the format of hlint options is [String] because they may contain
--     spaces and also <file> may contain spaces.
--  boot
--  browse [<package>:]<module>
--  quit
--
-- Session separators:
--   OK -- success
--   NG -- failure

module Main where

import Config (cProjectVersion)
import Control.Applicative ((<$>))
import Control.Concurrent (forkIO, MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (SomeException(..), Exception)
import qualified Control.Exception as E
import Control.Monad (when, void)
import CoreMonad (liftIO)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Typeable (Typeable)
import Data.Version (showVersion)
import GHC (Ghc, TargetId(TargetFile))
import qualified GHC as G
import Language.Haskell.GhcMod
import Language.Haskell.GhcMod.Ghc
import Language.Haskell.GhcMod.Internal
import Paths_ghc_mod
import System.Console.GetOpt
import System.Directory (setCurrentDirectory)
import System.Environment (getArgs)
import System.IO (hFlush,stdout)

import Boot

----------------------------------------------------------------

type Logger = IO String

----------------------------------------------------------------

progVersion :: String
progVersion = "ghc-modi version " ++ showVersion version ++ " compiled by GHC " ++ cProjectVersion ++ "\n"

argspec :: [OptDescr (Options -> Options)]
argspec = [ Option "b" ["boundary"]
            (ReqArg (\s opts -> opts { lineSeparator = LineSeparator s }) "sep")
            "specify line separator (default is Nul string)"
          , Option "l" ["tolisp"]
            (NoArg (\opts -> opts { outputStyle = LispStyle }))
            "print as a list of Lisp"
          , Option "g" []
            (ReqArg (\s opts -> opts { ghcOpts = s : ghcOpts opts }) "flag") "specify a ghc flag"
          ]

usage :: String
usage =    progVersion
        ++ "Usage:\n"
        ++ "\t ghc-modi [-l] [-b sep] [-g flag]\n"
        ++ "\t ghc-modi version\n"
        ++ "\t ghc-modi help\n"

parseArgs :: [OptDescr (Options -> Options)] -> [String] -> (Options, [String])
parseArgs spec argv
    = case getOpt Permute spec argv of
        (o,n,[]  ) -> (foldr id defaultOptions o, n)
        (_,_,errs) -> E.throw (CmdArg errs)

----------------------------------------------------------------

data GHCModiError = CmdArg [String]
                  deriving (Show, Typeable)

instance Exception GHCModiError

----------------------------------------------------------------

-- Running two GHC monad threads disables the handling of
-- C-c since installSignalHandlers is called twice, sigh.

main :: IO ()
main = E.handle cmdHandler $
    go =<< parseArgs argspec <$> getArgs
  where
    cmdHandler (CmdArg _) = putStr $ usageInfo usage argspec
    go (_,"help":_) = putStr $ usageInfo usage argspec
    go (_,"version":_) = putStr progVersion
    go (opt,_) = E.handle someHandler $ do
        cradle0 <- findCradle
        let rootdir = cradleRootDir cradle0
            cradle = cradle0 { cradleCurrentDir = rootdir }
        setCurrentDirectory rootdir
        mvar <- liftIO newEmptyMVar
        mlibdir <- getSystemLibDir
        void $ forkIO $ setupDB cradle mlibdir opt mvar
        run cradle mlibdir opt $ loop opt S.empty mvar
      where
        -- this is just in case.
        -- If an error is caught here, it is a bug of GhcMod library.
        someHandler (SomeException e) = do
            putStrLn $ "NG " ++ replace (show e)

replace :: String -> String
replace [] = []
replace ('\n':xs) = ';' : replace xs
replace (x:xs)    =  x  : replace xs

----------------------------------------------------------------

run :: Cradle -> Maybe FilePath -> Options -> Ghc a -> IO a
run cradle mlibdir opt body = G.runGhc mlibdir $ do
    initializeFlagsWithCradle opt cradle
    dflags <- G.getSessionDynFlags
    G.defaultCleanupHandler dflags body

----------------------------------------------------------------

setupDB :: Cradle -> Maybe FilePath -> Options -> MVar SymMdlDb -> IO ()
setupDB cradle mlibdir opt mvar = E.handle handler $ do
    db <- run cradle mlibdir opt getSymMdlDb
    putMVar mvar db
  where
    handler (SomeException _) = return () -- fixme: put emptyDb?

----------------------------------------------------------------

loop :: Options -> Set FilePath -> MVar SymMdlDb -> Ghc ()
loop opt set mvar = do
    cmdArg <- liftIO getLine
    let (cmd,arg') = break (== ' ') cmdArg
        arg = dropWhile (== ' ') arg'
    (ret,ok,set') <- case cmd of
        "check"  -> checkStx opt set arg
        "find"   -> findSym  opt set arg mvar
        "lint"   -> lintStx  opt set arg
        "info"   -> showInfo opt set arg
        "type"   -> showType opt set arg
        "boot"   -> bootIt   opt set
        "browse" -> browseIt opt set arg
        "quit"   -> return ("quit", False, set)
        ""       -> return ("quit", False, set)
        _        -> return ([], True, set)
    if ok then do
        liftIO $ putStr ret
        liftIO $ putStrLn "OK"
      else do
        liftIO $ putStrLn $ "NG " ++ replace ret
    liftIO $ hFlush stdout
    when ok $ loop opt set' mvar

----------------------------------------------------------------

checkStx :: Options
         -> Set FilePath
         -> FilePath
         -> Ghc (String, Bool, Set FilePath)
checkStx opt set file = do
    (set',add) <- removeMainTarget file set
    let files = if add then [file] else []
    eret <- withLogger opt setAllWaringFlags $ addTargetFiles files
    case eret of
        Right ret -> return (ret, True, set')
        Left ret  -> return (ret, True, set) -- fxime: set

removeMainTarget :: FilePath -> Set FilePath -> Ghc (Set FilePath, Bool)
removeMainTarget file set = do
    mx <- find isMain <$> G.getModuleGraph
    mdel <- tryRemove mx
    let set' = del mdel
    return (set',add)
  where
    add = not $ S.member file set
    set1 = if add then S.insert file set else set
    del Nothing      = set1
    del (Just delfl) = S.delete delfl set1
    isMain m = G.moduleNameString (G.moduleName (G.ms_mod m)) == "Main"
    tryRemove Nothing = return Nothing
    tryRemove (Just x) = do
        let mmainfile = G.ml_hs_file (G.ms_location x)
            -- G.ms_hspp_file x is a temporary file with CPP.
            -- this is a just fake.
            mainfile = fromMaybe (G.ms_hspp_file x) mmainfile
        if mainfile == file then
            return Nothing
          else do
            let target = TargetFile mainfile Nothing
            G.removeTarget target
            return $ Just mainfile

findSym :: Options -> Set FilePath -> String -> MVar SymMdlDb
        -> Ghc (String, Bool, Set FilePath)
findSym opt set sym mvar = do
    db <- liftIO $ readMVar mvar
    let ret = lookupSym opt sym db
    return (ret, True, set)

lintStx :: Options -> Set FilePath -> FilePath
        -> Ghc (String, Bool, Set FilePath)
lintStx opt set optFile = liftIO $ do
    ret <-lintSyntax opt' file
    return (ret, True, set)
  where
    (opts,file) = parseLintOptions optFile
    hopts = if opts == "" then [] else read opts
    opt' = opt { hlintOpts = hopts }

-- |
-- >>> parseLintOptions "[\"--ignore=Use camelCase\", \"--ignore=Eta reduce\"] file name"
-- (["--ignore=Use camelCase", "--ignore=Eta reduce"], "file name")
-- >>> parseLintOptions "file name"
-- ([], "file name")
parseLintOptions :: String -> (String, String)
parseLintOptions optFile = case brk (== ']') (dropWhile (/= '[') optFile) of
    ("","")      -> ([],   optFile)
    (opt',file') -> (opt', dropWhile (== ' ') file')
  where
    brk _ []         =  ([],[])
    brk p (x:xs')
        | p x        =  ([x],xs')
        | otherwise  =  let (ys,zs) = brk p xs' in (x:ys,zs)

----------------------------------------------------------------

showInfo :: Options
         -> Set FilePath
         -> FilePath
         -> Ghc (String, Bool, Set FilePath)
showInfo opt set fileArg = do
    let [file, expr] = words fileArg
    (set',_) <- removeMainTarget file set
    ret <- info opt file expr
    return (ret, True, set')

showType :: Options
         -> Set FilePath
         -> FilePath
         -> Ghc (String, Bool, Set FilePath)
showType opt set fileArg  = do
    let [file, line, column] = words fileArg
    (set',_) <- removeMainTarget file set
    ret <- types opt file (read line) (read column)
    return (ret, True, set')

----------------------------------------------------------------

bootIt :: Options
       -> Set FilePath
       -> Ghc (String, Bool, Set FilePath)
bootIt opt set = do
    ret <- boot' opt
    return (ret, True, set)

browseIt :: Options
         -> Set FilePath
         -> ModuleString
         -> Ghc (String, Bool, Set FilePath)
browseIt opt set mdl = do
    ret <- browse opt mdl
    return (ret, True, set)
