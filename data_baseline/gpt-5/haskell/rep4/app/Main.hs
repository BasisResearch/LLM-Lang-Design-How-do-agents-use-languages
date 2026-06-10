{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Web.Scotty
import qualified Data.Text as T
import           Data.Text (Text)
import qualified Data.Text.Lazy as TL
import           Data.Aeson (FromJSON(..), ToJSON(..), (.=), (.:), (.:?), withObject, object)
import qualified Data.Aeson as A
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad (when)
import           Data.Time
import           Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.Map.Strict as M
import           Data.Map.Strict (Map)
import           Control.Concurrent.STM
import           System.Environment (getArgs)
import           Network.HTTP.Types (status201, status204, status400, status401, status404, status409)
import           Data.UUID (toText)
import qualified Data.UUID.V4 as UUIDv4
import           Network.Wai.Handler.Warp (setPort, setHost, defaultSettings, runSettings)
import           Network.Wai (requestHeaders, pathInfo)
import           Data.Maybe (fromMaybe)
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text.Read as TR

-- Data Types

data User = User { userId :: Int, username :: Text } deriving (Show, Eq)
instance ToJSON User where
  toJSON (User i u) = object ["id" .= i, "username" .= u]

data UserRecord = UserRecord { urUser :: User, urPassword :: Text } deriving (Show)

data Todo = Todo
  { todoId :: Int
  , todoUserId :: Int
  , title :: Text
  , description :: Text
  , completed :: Bool
  , createdAt :: Text
  , updatedAt :: Text
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON (Todo i _uid t d c ca ua) = object
    [ "id" .= i
    , "title" .= t
    , "description" .= d
    , "completed" .= c
    , "created_at" .= ca
    , "updated_at" .= ua
    ]

-- Requests

data RegisterReq = RegisterReq { rrUsername :: Text, rrPassword :: Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq
    <$> o .: "username"
    <*> o .: "password"

data LoginReq = LoginReq { lrUsername :: Text, lrPassword :: Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq
    <$> o .: "username"
    <*> o .: "password"

data PasswordReq = PasswordReq { prOld :: Text, prNew :: Text }
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \o -> PasswordReq
    <$> o .: "old_password"
    <*> o .: "new_password"

data CreateTodoReq = CreateTodoReq { ctrTitle :: Text, ctrDesc :: Maybe Text }
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \o -> CreateTodoReq
    <$> o .: "title"
    <*> o .:? "description"

data UpdateTodoReq = UpdateTodoReq { utrTitle :: Maybe Text, utrDesc :: Maybe Text, utrCompleted :: Maybe Bool }
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> UpdateTodoReq
    <$> o .:? "title"
    <*> o .:? "description"
    <*> o .:? "completed"

-- Time formatting: UTC ISO8601 with seconds and Z
nowIso :: IO Text
nowIso = do
  t <- getCurrentTime
  let s = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t
  pure (T.pack s)

-- State

data AppState = AppState
  { usersById   :: TVar (Map Int UserRecord)
  , usersByName :: TVar (Map Text Int)
  , nextUserId  :: TVar Int
  , todosById   :: TVar (Map Int Todo)
  , userTodos   :: TVar (Map Int [Int])
  , nextTodoId  :: TVar Int
  , sessions    :: TVar (Map Text Int) -- token -> userId
  }

newState :: IO AppState
newState = atomically $ do
  uId <- newTVar 1
  tId <- newTVar 1
  AppState <$> newTVar M.empty <*> newTVar M.empty <*> pure uId
           <*> newTVar M.empty <*> newTVar M.empty <*> pure tId
           <*> newTVar M.empty

-- Cookie parsing
parseCookies :: BS.ByteString -> [(BS.ByteString, BS.ByteString)]
parseCookies bs = map splitEq $ filter (not . BS.null) $ map BS.strip $ BS.split ';' bs
  where
    splitEq x = let (k,v) = BS.break (=='=') x in (k, if BS.null v then BS.empty else BS.drop 1 v)

-- Helpers
setJson :: ActionM ()
setJson = setHeader "Content-Type" "application/json"

sendJSON :: ToJSON a => a -> ActionM ()
sendJSON a = do json a; setJson

bsToText :: BS.ByteString -> Text
bsToText = T.pack . BS.unpack

getSessionUser :: AppState -> ActionM (Maybe User)
getSessionUser st = do
  req <- request
  let mCookie = lookup "Cookie" (requestHeaders req)
  case mCookie of
    Nothing -> return Nothing
    Just ck -> do
      let parsed = parseCookies ck
          mTok = lookup "session_id" parsed
      case mTok of
        Nothing -> return Nothing
        Just tok -> liftIO . atomically $ do
          sess <- readTVar (sessions st)
          case M.lookup (bsToText tok) sess of
            Nothing -> return Nothing
            Just uid -> do
              umap <- readTVar (usersById st)
              return $ urUser <$> M.lookup uid umap

requireAuth :: AppState -> ActionM User
requireAuth st = do
  mu <- getSessionUser st
  case mu of
    Nothing -> do
      status status401
      sendJSON (object ["error" .= ("Authentication required" :: Text)])
      finish
    Just u -> return u

validUsername :: Text -> Bool
validUsername t = let l = T.length t
                  in l >= 3 && l <= 50 && T.all (\c -> T.any (==c) allowed) t
  where allowed = T.pack (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "_")

getPathId :: ActionM Int
getPathId = do
  req <- request
  let segs = pathInfo req
  case reverse segs of
    (sid:_) -> case TR.decimal sid of
                 Right (n, rest) | T.null rest -> return n
                 _ -> sendError404 >> finish
    _ -> sendError404 >> finish
  where
    sendError404 = do status status404; sendJSON (object ["error" .= ("Todo not found" :: Text)])

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
               ("--port":p:_) -> read p
               _               -> 3000
  st <- newState
  app <- scottyApp $ do
    -- POST /register
    post "/register" $ do
      RegisterReq u p <- jsonData
      when (not $ validUsername u) $ do
        status status400 >> sendJSON (object ["error" .= ("Invalid username" :: Text)]) >> finish
      when (T.length p < 8) $ do
        status status400 >> sendJSON (object ["error" .= ("Password too short" :: Text)]) >> finish
      res <- liftIO . atomically $ do
        names <- readTVar (usersByName st)
        if M.member u names then return (Left ()) else do
          nid <- readTVar (nextUserId st)
          let user = User nid u
              rec  = UserRecord user p
          writeTVar (nextUserId st) (nid+1)
          modifyTVar' (usersById st) (M.insert nid rec)
          modifyTVar' (usersByName st) (M.insert u nid)
          return (Right user)
      case res of
        Left _ -> status status409 >> sendJSON (object ["error" .= ("Username already exists" :: Text)])
        Right user -> status status201 >> sendJSON user

    -- POST /login
    post "/login" $ do
      LoginReq u p <- jsonData
      mres <- liftIO . atomically $ do
        names <- readTVar (usersByName st)
        case M.lookup u names of
          Nothing -> return Nothing
          Just uid -> do
            umap <- readTVar (usersById st)
            case M.lookup uid umap of
              Just (UserRecord usr pass) | pass == p -> return (Just usr)
              _ -> return Nothing
      case mres of
        Nothing -> status status401 >> sendJSON (object ["error" .= ("Invalid credentials" :: Text)])
        Just usr -> do
          tok <- liftIO $ fmap (T.replace "-" "" . toText) UUIDv4.nextRandom
          liftIO . atomically $ modifyTVar' (sessions st) (M.insert tok (userId usr))
          addHeader "Set-Cookie" (TL.fromStrict $ T.concat ["session_id=", tok, "; Path=/; HttpOnly"])
          sendJSON usr

    -- POST /logout
    post "/logout" $ do
      _usr <- requireAuth st
      req <- request
      let mCookie = lookup "Cookie" (requestHeaders req)
      case mCookie of
        Nothing -> return ()
        Just ck -> do
          let parsed = parseCookies ck
              mTok = lookup "session_id" parsed
          case mTok of
            Nothing -> return ()
            Just tok -> liftIO . atomically $ modifyTVar' (sessions st) (M.delete (bsToText tok))
      sendJSON (object [])

    -- GET /me
    get "/me" $ do
      usr <- requireAuth st
      sendJSON usr

    -- PUT /password
    put "/password" $ do
      usr <- requireAuth st
      PasswordReq old newp <- jsonData
      when (T.length newp < 8) $ do
        status status400 >> sendJSON (object ["error" .= ("Password too short" :: Text)]) >> finish
      ok <- liftIO . atomically $ do
        umap <- readTVar (usersById st)
        case M.lookup (userId usr) umap of
          Just (UserRecord urec pass) | pass == old -> do
            let rec' = UserRecord urec newp
            modifyTVar' (usersById st) (M.insert (userId usr) rec')
            return True
          _ -> return False
      if ok then sendJSON (object []) else status status401 >> sendJSON (object ["error" .= ("Invalid credentials" :: Text)])

    -- GET /todos
    get "/todos" $ do
      usr <- requireAuth st
      ts <- liftIO . atomically $ do
        idsMap <- readTVar (userTodos st)
        tmap <- readTVar (todosById st)
        let ids = fromMaybe [] (M.lookup (userId usr) idsMap)
            todos = mapMaybe (`M.lookup` tmap) ids
        return todos
      sendJSON (A.toJSON (sortById ts))

    -- POST /todos
    post "/todos" $ do
      usr <- requireAuth st
      CreateTodoReq t md <- jsonData
      when (T.strip t == "") $ do
        status status400 >> sendJSON (object ["error" .= ("Title is required" :: Text)]) >> finish
      now <- liftIO nowIso
      todo <- liftIO . atomically $ do
        nid <- readTVar (nextTodoId st)
        let td = Todo nid (userId usr) t (fromMaybe "" md) False now now
        writeTVar (nextTodoId st) (nid+1)
        modifyTVar' (todosById st) (M.insert nid td)
        modifyTVar' (userTodos st) (M.insertWith (++) (userId usr) [nid])
        return td
      status status201
      sendJSON todo

    -- GET /todos/:id
    get "/todos/:id" $ do
      usr <- requireAuth st
      tid <- getPathId
      mtd <- liftIO . atomically $ do
        tmap <- readTVar (todosById st)
        return $ M.lookup tid tmap
      case mtd of
        Just td | todoUserId td == userId usr -> sendJSON td
        _ -> status status404 >> sendJSON (object ["error" .= ("Todo not found" :: Text)])

    -- PUT /todos/:id
    put "/todos/:id" $ do
      usr <- requireAuth st
      tid <- getPathId
      bodyV <- jsonData :: ActionM UpdateTodoReq
      res <- liftIO . atomically $ do
        tmap <- readTVar (todosById st)
        case M.lookup tid tmap of
          Nothing -> return (Left ())
          Just td -> if todoUserId td /= userId usr
                        then return (Left ())
                        else return (Right td)
      case res of
        Left _ -> status status404 >> sendJSON (object ["error" .= ("Todo not found" :: Text)])
        Right td -> do
          case utrTitle bodyV of
            Just t | T.strip t == "" -> status status400 >> sendJSON (object ["error" .= ("Title is required" :: Text)]) >> finish
            _ -> return ()
          now <- liftIO nowIso
          let newTitle = fromMaybe (title td) (utrTitle bodyV)
              newDesc  = fromMaybe (description td) (utrDesc bodyV)
              newComp  = fromMaybe (completed td) (utrCompleted bodyV)
              td' = td { title = newTitle, description = newDesc, completed = newComp, updatedAt = now }
          liftIO . atomically $ modifyTVar' (todosById st) (M.insert tid td')
          sendJSON td'

    -- DELETE /todos/:id
    delete "/todos/:id" $ do
      usr <- requireAuth st
      tid <- getPathId
      mdel <- liftIO . atomically $ do
        tmap <- readTVar (todosById st)
        case M.lookup tid tmap of
          Nothing -> return Nothing
          Just td -> if todoUserId td /= userId usr
                        then return Nothing
                        else do
                          modifyTVar' (todosById st) (M.delete tid)
                          modifyTVar' (userTodos st) (M.adjust (filter (/= tid)) (userId usr))
                          return (Just ())
      case mdel of
        Nothing -> do
          status status404
          sendJSON $ object ["error" .= ("Todo not found" :: Text)]
        Just () -> do
          status status204
          raw ""

  let settings = setPort port $ setHost "0.0.0.0" defaultSettings
  runSettings settings app

-- Utilities
sortById :: [Todo] -> [Todo]
sortById = sortOn todoId

mapMaybe :: (a -> Maybe b) -> [a] -> [b]
mapMaybe f = foldr (\x acc -> case f x of
                                Nothing -> acc
                                Just y -> y:acc) []

sortOn :: Ord b => (a -> b) -> [a] -> [a]
sortOn f = map snd . M.toAscList . M.fromList . map (\x -> (f x, x))
