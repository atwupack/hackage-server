{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
module Distribution.Server (
    -- * Server control
    Server(..),
    ServerEnv(..),
    initialise,
    run,
    shutdown,
    checkpoint,

    -- * Server configuration
    ListenOn(..),
    ServerConfig(..),
    defaultServerConfig,
    hasSavedState,

    -- * Server state
    serverState,
    initState,

    -- * Temporary server while loading data
    setUpTemp,
    tearDownTemp
 ) where

import Distribution.Server.Framework
import qualified Distribution.Server.Framework.BackupRestore as Import
import qualified Distribution.Server.Framework.BlobStorage as BlobStorage
import qualified Distribution.Server.Framework.Auth as Auth
import Distribution.Server.Framework.Templating (TemplatesMode(NormalMode))
import Distribution.Server.Framework.AuthTypes (PasswdPlain(..))

import Distribution.Server.Framework.Feature as Feature
import qualified Distribution.Server.Features as Features
import Distribution.Server.Features.Users

import qualified Distribution.Server.Users.Types as Users
import qualified Distribution.Server.Users.Users as Users
import qualified Distribution.Server.Users.Group as Group

import Distribution.Text
import Distribution.Verbosity as Verbosity

import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import Control.Concurrent
import Network.URI (URI(..), URIAuth(URIAuth), nullURI)
import Network.BSD (getHostName)
import Data.List (foldl', nubBy)
import Data.Int  (Int64)
import Control.Arrow (second)
import Data.Function (on)
import qualified System.Log.Logger as HsLogger

import Paths_hackage_server (getDataDir)


data ListenOn = ListenOn {
  loPortNum :: Int,
  loIP :: String
} deriving (Show)

data ServerConfig = ServerConfig {
  confVerbosity :: Verbosity,
  confHostUri   :: URI,
  confListenOn  :: ListenOn,
  confStateDir  :: FilePath,
  confStaticDir :: FilePath,
  confTmpDir    :: FilePath,
  confCacheDelay:: Int
} deriving (Show)

confDbStateDir, confBlobStoreDir,
  confStaticFilesDir, confTemplatesDir :: ServerConfig -> FilePath
confDbStateDir   config = confStateDir config </> "db"
confBlobStoreDir config = confStateDir config </> "blobs"
confStaticFilesDir config = confStaticDir config </> "static"
confTemplatesDir   config = confStaticDir config </> "templates"

defaultServerConfig :: IO ServerConfig
defaultServerConfig = do
  hostName <- getHostName
  dataDir  <- getDataDir
  let portnum = 8080 :: Int
  return ServerConfig {
    confVerbosity = Verbosity.normal,
    confHostUri   = nullURI {
                      uriScheme    = "http:",
                      uriAuthority = Just (URIAuth "" hostName (':' : show portnum))
                    },
    confListenOn  = ListenOn {
                        loPortNum = 8080,
                        loIP = "0.0.0.0"
                    },
    confStateDir  = "state",
    confStaticDir = dataDir,
    confTmpDir    = "state" </> "tmp",
    confCacheDelay= 0
  }

data Server = Server {
  serverFeatures    :: [HackageFeature],
  serverUserFeature :: UserFeature,
  serverListenOn    :: ListenOn,
  serverEnv         :: ServerEnv
}

-- | If we made a server instance from this 'ServerConfig', would we find some
-- existing saved state or would it be a totally clean instance with no
-- existing state.
--
hasSavedState :: ServerConfig -> IO Bool
hasSavedState = doesDirectoryExist . confDbStateDir

-- | Make a server instance from the server configuration.
--
-- This does not yet run the server (see 'run') but it does setup the server
-- state system, making it possible to import data, and initializes the
-- features.
--
-- Note: the server instance must eventually be 'shutdown' or you'll end up
-- with stale lock files.
--
initialise :: ServerConfig -> IO Server
initialise config@(ServerConfig verbosity hostURI listenOn
                                    stateDir _ tmpDir
                                    cacheDelay) = do
    createDirectoryIfMissing False stateDir
    let blobStoreDir  = confBlobStoreDir   config
        staticDir     = confStaticFilesDir config
        templatesDir  = confTemplatesDir   config

    store   <- BlobStorage.open blobStoreDir

    let env = ServerEnv {
            serverStaticDir     = staticDir,
            serverTemplatesDir  = templatesDir,
            serverTemplatesMode = NormalMode,
            serverStateDir      = stateDir,
            serverBlobStore     = store,
            serverTmpDir        = tmpDir,
            serverCacheDelay    = cacheDelay * 1000000, --microseconds
            serverBaseURI       = hostURI,
            serverVerbosity     = verbosity
         }
    -- do feature initialization
    (features, userFeature) <- Features.initHackageFeatures env

    return Server {
        serverFeatures    = features,
        serverUserFeature = userFeature,
        serverListenOn    = listenOn,
        serverEnv         = env
    }

-- | Actually run the server, i.e. start accepting client http connections.
--
run :: Server -> IO ()
run server = do
    -- We already check this in Main, so we expect this check to always
    -- succeed, but just in case...
    let staticDir = serverStaticDir (serverEnv server)
    exists <- doesDirectoryExist staticDir
    when (not exists) $ fail $ "The static files directory " ++ staticDir ++ " does not exist."

    runServer listenOn $ do

      handlePutPostQuotas

      setLogging

      fakeBrowserHttpMethods (impl server)

  where
    listenOn = serverListenOn server

    -- HS6 - Quotas should be configurable as well. Also there are places in
    -- the code that want to work with the request body directly but maybe
    -- fail if the request body has already been consumed. The body will only
    -- be consumed if it is a POST/PUT request *and* the content-type is
    -- multipart/form-data. If this does happen, you should get a clear error
    -- message saying what happened.
    handlePutPostQuotas = decodeBody bodyPolicy
      where
        tmpdir = serverTmpDir (serverEnv server)
        quota  = 50 * (1024 ^ (2:: Int64))
                -- setting quota at 50mb, though perhaps should be configurable?
        bodyPolicy = defaultBodyPolicy tmpdir quota quota quota

    setLogging =
        liftIO $ HsLogger.updateGlobalLogger
                   "Happstack.Server"
                   (adjustLogLevel (serverVerbosity (serverEnv server)))
      where
        adjustLogLevel v
          | v == Verbosity.normal    = HsLogger.setLevel HsLogger.WARNING
          | v == Verbosity.verbose   = HsLogger.setLevel HsLogger.INFO
          | v == Verbosity.deafening = HsLogger.setLevel HsLogger.DEBUG
          | otherwise                = id

    -- This is a cunning hack to solve the problem that current web browsers
    -- (non-HTML5 forms) do not support PUT, DELETE, etc, they only support GET
    -- and POST. We don't want to compromise the design of the whole server
    -- just because of browsers not supporting HTTP properly, so we allow
    -- browsers to PUT/DELETE etc by POSTing with a query or body paramater of
    -- _method=PUT/DELETE.
    fakeBrowserHttpMethods part =
      msum [ do method POST
                methodOverrideHack part

             -- or just do things the normal way
           , part
           ]


-- | Perform a clean shutdown of the server.
--
shutdown :: Server -> IO ()
shutdown server =
  Features.shutdownAllFeatures (serverFeatures server)

--TODO: stop accepting incomming connections,
-- wait for connections to be processed.

-- | Write out a checkpoint of the server state. This makes recovery quicker
-- because fewer logged transactions have to be replayed.
--
checkpoint :: Server -> IO ()
checkpoint server =
  Features.checkpointAllFeatures (serverFeatures server)

-- | Return /one/ abstract state component per feature
serverState :: Server -> [(String, AbstractStateComponent)]
serverState server = [ (featureName feature, mconcat (featureState feature))
                     | feature <- serverFeatures server
                     ]

-- An alternative to an import: starts the server off to a sane initial state.
-- To accomplish this, we import a 'null' tarball, finalizing immediately after initializing import
initState ::  Server -> (String, String) -> IO ()
initState server (admin, pass) = do
    let store = serverBlobStore (serverEnv server)
    void . Import.importBlank store $ map (second abstractStateRestore) (serverState server)
    -- create default admin user
    let UserFeature{updateAddUser, adminGroup} = serverUserFeature server
    muid <- case simpleParse admin of
        Just uname -> do
            let userAuth = Auth.newPasswdHash Auth.hackageRealm uname (PasswdPlain pass)
            updateAddUser uname (Users.UserAuth userAuth)
        Nothing -> fail "Couldn't parse admin name (should be alphanumeric)"
    case muid of
        Right uid -> Group.addUserList adminGroup uid
        Left Users.ErrUserNameClash -> fail $ "Inconceivable!! failed to create admin user"

-- The top-level server part.
-- It collects resources from Distribution.Server.Features, collects
-- them into a path hierarchy, and serves them.
impl :: Server -> ServerPart Response
impl server =
    runServerPartE $
      handleErrorResponse (serveErrorResponse errHandlers Nothing) $
        renderServerTree [] serverTree
          `mplus`
        fallbackNotFound
  where
    serverTree :: ServerTree (DynamicPath -> ServerPartE Response)
    serverTree =
        fmap (serveResource errHandlers)
      -- ServerTree Resource
      . foldl' (\acc res -> addServerNode (resourceLocation res) res acc) serverTreeEmpty
      -- [Resource]
      $ concatMap Feature.featureResources (serverFeatures server)

    errHandlers = nubBy ((==) `on` fst)
                . reverse
                . (("txt", textErrorPage):)
                . concatMap Feature.featureErrHandlers
                $ serverFeatures server

    -- This basic one be overridden in another feature but means even in a
    -- minimal server we can provide content-negoticated text/plain errors
    textErrorPage :: ErrorResponse -> ServerPartE Response
    textErrorPage = return . toResponse

    fallbackNotFound =
      errNotFound "Page not found"
        [MText "Sorry, it's just not here."]


data TempServer = TempServer ThreadId

setUpTemp :: ServerConfig -> Int -> IO TempServer
setUpTemp sconf secs = do
    tid <- forkIO $ do
        -- wait a certain amount of time before setting it up, because sometimes
        -- happstack-state is very fast, and switching the servers has a time
        -- cost to it
        threadDelay $ secs*1000000
        -- could likewise specify a mirror to redirect to for tarballs, and 503 for everything else
        runServer listenOn $ (resp 503 $ setHeader "Content-Type" "text/html" $ toResponse html503)
    return (TempServer tid)
  where listenOn = confListenOn sconf

runServer :: (ToMessage a) => ListenOn -> ServerPartT IO a -> IO ()
runServer listenOn f
    = do socket <- bindIPv4 (loIP listenOn) (loPortNum listenOn)
         simpleHTTPWithSocket socket nullConf f

-- | Static 503 page, based on Happstack's 404 page.
html503 :: String
html503 =
    "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">" ++
    "<html><head><title>503 Service Unavailable</title></head><body><h1>" ++
    "503 Service Unavailable</h1><p>The server is undergoing maintenance" ++
    "<br>It'll be back soon</p></body></html>"

tearDownTemp :: TempServer -> IO ()
tearDownTemp (TempServer tid) = do
    killThread tid
    -- give the server enough time to release the bind
    threadDelay $ 1000000

