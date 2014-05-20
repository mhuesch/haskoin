{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE TypeFamilies      #-}
module Main where

import System.Directory 
    ( getAppUserDataDirectory
    , createDirectoryIfMissing
    )
import System.IO.Error (ioeGetErrorString)
import System.Console.GetOpt 
    ( getOpt
    , usageInfo
    , OptDescr( Option )
    , ArgDescr( NoArg, ReqArg )
    , ArgOrder( Permute )
    )
import qualified System.Environment as E (getArgs)

import Control.Monad (forM_, join, when)
import Control.Monad.Trans (lift, liftIO, MonadIO)
import Control.Exception (tryJust, throwIO)
import Control.Monad.Logger (MonadLogger, logErrorN, runStderrLoggingT)

import Database.Persist
    ( PersistStore
    , PersistUnique
    , PersistQuery
    , PersistMonadBackend
    )
import Database.Persist.Sql ()
import Database.Persist.Sqlite (SqlBackend, runSqlite, runMigrationSilent)

import Data.Maybe (listToMaybe, fromJust, isNothing)
import qualified Data.Text as T (pack, unpack, splitOn)
import qualified Data.Yaml as YAML 
    ( Value(Null)
    , encode
    )
import qualified Data.Aeson.Encode.Pretty as JSON
    ( encodePretty'
    , defConfig
    , confIndent
    )

import Network.Haskoin.Wallet.Commands
import Network.Haskoin.Wallet.Model
import Network.Haskoin.Script
import Network.Haskoin.Crypto
import Network.Haskoin.Util
import Network.Haskoin.Util.Network

data Options = Options
    { optCount    :: Int
    , optSigHash  :: SigHash
    , optFee      :: Int
    , optJson     :: Bool
    , optHelp     :: Bool
    , optVersion  :: Bool
    , optPass     :: String
    } deriving (Eq, Show)

defaultOptions :: Options
defaultOptions = Options
    { optCount    = 5
    , optSigHash  = SigAll False
    , optFee      = 10000
    , optJson     = False
    , optHelp     = False
    , optVersion  = False
    , optPass     = ""
    } 

options :: [OptDescr (Options -> IO Options)]
options =
    [ Option ['c'] ["count"] (ReqArg parseCount "INT") $
        "Count: see commands for details"
    , Option ['s'] ["sighash"] (ReqArg parseSigHash "SIGHASH") $
        "Signature type = ALL|NONE|SINGLE"
    , Option ['a'] ["anyonecanpay"]
        (NoArg $ \opts -> do
            let sh = optSigHash opts
            return opts{ optSigHash = sh{ anyoneCanPay = True } }
        ) $ "Set signature flag AnyoneCanPay"
    , Option ['f'] ["fee"] (ReqArg parseCount "INT") $
        "Transaction fee (default: 10000)"
    , Option ['j'] ["json"]
        (NoArg $ \opts -> return opts{ optJson = True }) $
        "Format result as JSON (default: YAML)"
    , Option ['h'] ["help"]
        (NoArg $ \opts -> return opts{ optHelp = True }) $
        "Display this help message"
    , Option ['v'] ["version"]
        (NoArg $ \opts -> return opts{ optVersion = True }) $
        "Show version information"
    , Option ['p'] ["passphrase"]
        (ReqArg (\s opts -> return opts{ optPass = s }) "PASSPHRASE") $
        "Optional Passphrase for mnemonic"
    ]

parseCount :: String -> Options -> IO Options
parseCount s opts 
    | res > 0   = return opts{ optCount = res }
    | otherwise = error $ unwords ["Invalid count option:", s]
    where res = read s

parseSigHash :: String -> Options -> IO Options
parseSigHash s opts = return opts{ optSigHash = res }
    where acp = anyoneCanPay $ optSigHash opts
          res | s == "ALL" = SigAll acp
              | s == "NONE" = SigNone acp
              | s == "SINGLE" = SigSingle acp
              | otherwise = error "SigHash must be one of ALL|NONE|SINGLE"

usageHeader :: String
usageHeader = "Usage: hw [<options>] <command> [<args>]"

cmdHelp :: [String]
cmdHelp = 
    [ "hw wallet commands: " 
    , "  init       [mnemonic]              Initialize a wallet"
    , "  list       acc                     Display last page of addresses"
    , "  listpage   acc page [-c res/page]  Display addresses by page"
    , "  new        acc {labels...}         Generate address with labels"
    , "  genaddr    acc [-c count]          Generate new addresses"
    , "  label      acc index label         Add a label to an address"
    , "  balance    acc                     Display account balance"
    , "  balances                           Display all balances"
    , "  tx         acc                     Display transactions"
    , "  send       acc addr amount         Send coins to an address"
    , "  sendmany   acc {addr:amount...}    Send coins to many addresses"
    , "  newacc     name                    Create a new account"
    , "  newms      name M N [pubkey...]    Create a new multisig account"
    , "  addkeys    acc {pubkey...}         Add pubkeys to a multisig account"
    , "  accinfo    acc                     Display account information"
    , "  listacc                            List all accounts"
    , "  dumpkeys   acc                     Dump account keys to stdout"
    , "  wif        acc index               Dump prvkey as WIF to stdout"
    , "  coins      acc                     List coins"
    , "  allcoins                           List all coins per account"
    , "  signtx     acc tx                  Sign a transaction"
    , "  importtx   tx                      Import transaction"
    , "  removetx   txid                    Remove transaction"
    , ""
    , "hw utility commands: "
    , "  decodetx   tx                      Decode HEX transaction"
    , "  buildrawtx"
    , "      '[{\"txid\":txid,\"vout\":n},...]' '{addr:amnt,...}'"
    , "  signrawtx "  
    , "      tx" 
    , "      " ++ sigdata
    , "      '[prvkey,...]' [-s SigHash]" 
    ]
  where 
    sigdata = concat
        [ "'[{"
        , "\"txid\":txid,"
        , "\"vout\":n,"
        , "\"scriptPubKey\":hex,"
        , "\"scriptRedeem\":hex"
        , "},...]'"
        ]

warningMsg :: String
warningMsg = unwords [ "***"
                     , "This software is experimental."
                     , "Use only small amounts of Bitcoins"
                     , "***"
                     ]

versionMsg :: String
versionMsg = "haskoin wallet version 0.0.1"

usage :: String
usage = unlines $ [warningMsg, usageInfo usageHeader options] ++ cmdHelp

formatStr :: String -> IO ()
formatStr str = forM_ (lines str) putStrLn

main :: IO ()
main = E.getArgs >>= \args -> case getOpt Permute options args of
    (o,xs,[]) -> do
        opts <- foldl (>>=) (return defaultOptions) o
        process opts xs
    (_,_,msgs) -> print $ unlines $ msgs ++ [usage]

-- Create and return haskoin working directory
getWorkDir :: IO FilePath
getWorkDir = do
    dir <- getAppUserDataDirectory "haskoin"
    createDirectoryIfMissing True dir
    return $ concat [dir, "/", walletFile]

catchEx :: IOError -> Maybe String
catchEx = return . ioeGetErrorString

process :: Options -> [String] -> IO ()
process opts xs 
    -- -h and -v can be called without a command
    | optHelp opts = formatStr usage
    | optVersion opts = print versionMsg
    -- otherwise require a command
    | null xs = formatStr usage
    | otherwise = getWorkDir >>= \dir -> do
        let (cmd,args) = (head xs, tail xs)

        valE <- tryJust catchEx $ runSqlite (T.pack dir) $ do
             _ <- runMigrationSilent migrateAll
             runStderrLoggingT $ dispatchCommand cmd opts args 

        -- TODO: Handle the exceptions
        when (isRight valE) $ do
            let val = fromRight valE
            if val == YAML.Null then return () else if optJson opts 
                then formatStr $ bsToString $ toStrictBS $ 
                    JSON.encodePretty' JSON.defConfig{ JSON.confIndent = 2 } val
                else formatStr $ bsToString $ YAML.encode val

type Command m = m YAML.Value
type Args = [String]

whenArgs :: (MonadLogger m, MonadIO m)
         => Args -> (Int -> Bool) -> Command m -> Command m
whenArgs args f cmd 
    | f $ length args = cmd
    | otherwise = do
        logErrorN $ T.pack "Invalid number of arguments"
        liftIO $ throwIO InvalidCommandException

dispatchCommand :: ( MonadLogger m
                   , PersistStore m
                   , PersistUnique m
                   , PersistQuery m
                   , PersistMonadBackend m ~ SqlBackend
                   ) 
                => String -> Options -> Args -> Command m
dispatchCommand cmd opts args = case cmd of
    "init" -> whenArgs args (<= 1) $
        cmdInitMnemo (optPass opts) (listToMaybe args)
    "list" -> whenArgs args (== 1) $ cmdList (head args) 0 (optCount opts)
    "listpage" -> whenArgs args (== 2) $ 
        cmdList (head args) (read $ args !! 1) (optCount opts)
    "new" -> whenArgs args (>= 2) $ cmdGenWithLabel (head args) $ drop 1 args
    "genaddr" -> whenArgs args (== 1) $ cmdGenAddrs (head args) (optCount opts)
    "label" -> whenArgs args (== 3) $ 
        cmdLabel (head args) (read $ args !! 1) (args !! 2)
    "balance" -> whenArgs args (== 1) $ cmdBalance $ head args
    "balances" -> whenArgs args (== 0) cmdBalances
    "tx" -> whenArgs args (== 1) $ cmdListTx $ head args
    "send" -> whenArgs args (== 3) $ 
        cmdSend (head args) (args !! 1) (read $ args !! 2) (optFee opts)
    "sendmany" -> whenArgs args (>= 2) $ do
        let f [a,b] = (T.unpack a,read $ T.unpack b)
            f _     = error "sendmany: Invalid format addr:amount"
            dests   = map (f . (T.splitOn (T.pack ":")) . T.pack) $ drop 1 args
        cmdSendMany (head args) dests (optFee opts)
    "newacc" -> whenArgs args (== 1) $ cmdNewAcc $ head args
    "newms" -> whenArgs args (>= 3) $ do
        let keysM = mapM xPubImport $ drop 3 args
            keys  = fromJust keysM
        when (isNothing keysM) $ do
            logErrorN $ T.pack "Could not decode keys"
            liftIO $ throwIO CouldNotDecodeException
        cmdNewMS (args !! 0) (read $ args !! 1) (read $ args !! 2) keys
    "addkeys" -> whenArgs args (>= 2) $ do
        let keysM = mapM xPubImport $ drop 1 args
            keys  = fromJust keysM
        when (isNothing keysM) $ do
            logErrorN $ T.pack "Could not decode keys"
            liftIO $ throwIO CouldNotDecodeException
        cmdAddKeys (head args) keys
    "accinfo" -> whenArgs args (== 1) $ cmdAccInfo $ head args
    "listacc" -> whenArgs args (== 0) cmdListAcc 
    "dumpkeys" -> whenArgs args (== 1) $ cmdDumpKeys $ head args
    "wif" -> whenArgs args (== 2) $ cmdWIF (head args) (read $ args !! 1)
    "coins" -> whenArgs args (== 1) $ cmdCoins $ head args
    "allcoins" -> whenArgs args (== 0) cmdAllCoins
    "signtx" -> whenArgs args (== 2) $ do
        let txM = decodeToMaybe =<< (hexToBS $ args !! 1)
            tx  = fromJust txM
        when (isNothing txM) $ do
            logErrorN $ T.pack "Could not decode transaction"
            liftIO $ throwIO CouldNotDecodeException
        cmdSignTx (head args) tx (optSigHash opts)
    "importtx" -> whenArgs args (== 1) $ do
        let txM = decodeToMaybe =<< (hexToBS $ head args)
            tx  = fromJust txM
        when (isNothing txM) $ do
            logErrorN $ T.pack "Could not decode transaction"
            liftIO $ throwIO CouldNotDecodeException
        cmdImportTx tx
    "removetx" -> whenArgs args (== 1) $ cmdRemoveTx $ head args
    "decodetx" -> whenArgs args (== 1) $ cmdDecodeTx $ head args
    "buildrawtx" -> whenArgs args (== 2) $ cmdBuildRawTx (head args) (args !! 1)
    "signrawtx"    -> whenArgs args (== 3) $ do 
        let txM = decodeToMaybe =<< (hexToBS $ head args)
            tx  = fromJust txM
        when (isNothing txM) $ do
            logErrorN $ T.pack "Could not decode transaction"
            liftIO $ throwIO CouldNotDecodeException
        cmdSignRawTx tx (args !! 1) (args !! 2) (optSigHash opts)
    _ -> do
        logErrorN $ T.pack $ unwords ["Invalid command:", cmd]
        liftIO $ throwIO InvalidCommandException

