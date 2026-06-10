{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Main where

import           Control.Concurrent.STM
import qualified Data.Aeson                as A
import           Data.Aeson                 (FromJSON(..), ToJSON(..), (.:), (.:?), (.=), withObject, object)
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Lazy      as LBS
import qualified Data.Map.Strict           as M
import           Data.Maybe                 (fromMaybe)
import           Data.Text                  (Text)
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as TE
import           Data.Time.Clock            (UTCTime, getCurrentTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime)
import           Data.UUID                  (toText)
import           Data.UUID.V4               (nextRandom)
import           Network.HTTP.Types         (Status, status200, status201, status204, status400, status401, status404, status409, hContentType, Header)
import           Network.Wai                (Application, Request(..), Response, pathInfo, requestBody, requestHeaders, responseLBS)
import           Network.Wai.Handler.Warp   (defaultSettings, runSettings, setHost, setPort)
import           System.Environment         (getArgs)
import           Web.Cookie                 (SetCookie(..), defaultSetCookie, parseCookies, renderSetCookie)
import           Data.ByteString.Builder    (toLazyByteString)

-- Data types

data User = User { userId :: Int, username :: Text } deriving (Show, Eq)

instance ToJSON User where
  toJSON (User i u) = object ["id" .= i, "username" .= u]

data UserRec = UserRec { uUser :: User, uPassword :: Text } deriving (Show)

data Todo = Todo
  { todoId      :: Int
  , title       :: Text
  , description :: Text
  , completed   :: Bool
  , createdAt   :: UTCTime
  , updatedAt   :: UTCTime
  , ownerId     :: Int
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON t = object
    [ "id" .= todoId t
    , "title" .= title t
    , "description" .= description t
    , "completed" .= completed t
    , "created_at" .= formatUtc (createdAt t)
    , "updated_at" .= formatUtc (updatedAt t)
    ]

formatUtc :: UTCTime -> Text
formatUtc = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- Input payloads

data RegisterReq = RegisterReq { rUsername :: Text, rPassword :: Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq <$> o .: "username" <*> o .: "password"

data LoginReq = LoginReq { lUsername :: Text, lPassword :: Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq <$> o .: "username" <*> o .: "password"

data NewTodoReq = NewTodoReq { ntTitle :: Text, ntDescription :: Maybe Text }
instance FromJSON NewTodoReq where
  parseJSON = withObject "NewTodoReq" $ \o -> NewTodoReq <$> o .: "title" <*> o .:? "description"

data UpdateTodoReq = UpdateTodoReq { upTitle :: Maybe Text, upDescription :: Maybe Text, upCompleted :: Maybe Bool }
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> UpdateTodoReq <$> o .:? "title" <*> o .:? "description" <*> o .:? "completed"

data ChangePassReq = ChangePassReq { oldPass :: Text, newPass :: Text }
instance FromJSON ChangePassReq where
  parseJSON = withObject "ChangePassReq" $ \o -> ChangePassReq <$> o .: "old_password" <*> o .: "new_password"

-- In-memory store

data Store = Store
  { users      :: M.Map Int UserRec
  , usersByName:: M.Map Text Int
  , nextUserId :: Int
  , sessions   :: M.Map Text Int -- token -> userId
  , todos      :: M.Map Int Todo
  , userTodos  :: M.Map Int [Int] -- userId -> todo ids asc
  , nextTodoId :: Int
  }

defaultStore :: Store
defaultStore = Store M.empty M.empty 1 M.empty M.empty M.empty 1

-- Validation helpers
validUsername :: Text -> Bool
validUsername t =
  let s = T.unpack t
  in length s >= 3 && length s <= 50 && all (\c -> c == '_' || ('0'<=c && c<='9') || ('a'<=c && c<='z') || ('A'<=c && c<='Z')) s

-- Response helpers
json :: Status -> A.Value -> Response
json st v = responseLBS st [(hContentType, "application/json")] (A.encode v)

jsonOk :: A.ToJSON a => a -> Response
jsonOk a = json status200 (A.toJSON a)

jsonErr :: Status -> Text -> Response
jsonErr st msg = json st (object ["error" .= msg])

noBody :: Status -> Response
noBody st = responseLBS st [] LBS.empty

-- Cookie helpers
setSessionCookieHeader :: Text -> Header
setSessionCookieHeader tok =
  let sc = defaultSetCookie { setCookieName = "session_id"
                            , setCookieValue = TE.encodeUtf8 tok
                            , setCookiePath = Just "/"
                            , setCookieHttpOnly = True }
  in ("Set-Cookie", LBS.toStrict $ toLazyByteString $ renderSetCookie sc)

getSessionToken :: Request -> Maybe Text
getSessionToken req =
  let mCookieHeader = lookup "Cookie" (requestHeaders req)
  in case mCookieHeader of
    Nothing -> Nothing
    Just bs -> let cs = parseCookies bs in fmap TE.decodeUtf8 (lookup "session_id" cs)

-- Read body fully
readBody :: Request -> IO LBS.ByteString
readBody req = go []
  where
    go acc = do
      chunk <- requestBody req
      if BS.null chunk then pure (LBS.fromChunks (reverse acc)) else go (chunk:acc)

-- Auth helper: returns Maybe user id
getAuth :: TVar Store -> Request -> IO (Maybe Int)
getAuth tv req = atomically $ do
  st <- readTVar tv
  pure $ do
    tok <- getSessionToken req
    M.lookup tok (sessions st)

-- Handlers
handleRegister :: TVar Store -> Request -> IO Response
handleRegister tv req = do
  b <- readBody req
  case A.eitherDecode b of
    Left _ -> pure $ jsonErr status400 "Invalid username"
    Right (RegisterReq u p) ->
      if not (validUsername u)
        then pure $ jsonErr status400 "Invalid username"
        else if T.length p < 8
          then pure $ jsonErr status400 "Password too short"
          else atomically (do
            st <- readTVar tv
            if M.member u (usersByName st) then pure (Left st) else do
              let uid = nextUserId st
                  user = User uid u
                  st' = st { users = M.insert uid (UserRec user p) (users st)
                           , usersByName = M.insert u uid (usersByName st)
                           , nextUserId = uid + 1 }
              writeTVar tv st'
              pure (Right user)) >>= \case
                Left _    -> pure $ jsonErr status409 "Username already exists"
                Right usr -> pure $ responseLBS status201 [(hContentType, "application/json")] (A.encode usr)

handleLogin :: TVar Store -> Request -> IO Response
handleLogin tv req = do
  b <- readBody req
  case A.eitherDecode b of
    Left _ -> pure $ jsonErr status401 "Invalid credentials"
    Right (LoginReq u p) -> do
      muser <- atomically $ do
        st <- readTVar tv
        pure $ do
          uid <- M.lookup u (usersByName st)
          UserRec usr pass <- M.lookup uid (users st)
          if pass == p then Just usr else Nothing
      case muser of
        Nothing -> pure $ jsonErr status401 "Invalid credentials"
        Just usr -> do
          tok <- fmap (T.toLower . toText) nextRandom
          atomically $ modifyTVar' tv $ \st -> st { sessions = M.insert tok (userId usr) (sessions st) }
          let hdr = setSessionCookieHeader tok
          pure $ responseLBS status200 [(hContentType, "application/json"), hdr] (A.encode usr)

handleLogout :: TVar Store -> Request -> IO Response
handleLogout tv req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just _uid -> do
      case getSessionToken req of
        Nothing  -> pure ()
        Just tok -> atomically $ modifyTVar' tv $ \st -> st { sessions = M.delete tok (sessions st) }
      pure $ json status200 (A.object [])

handleMe :: TVar Store -> Request -> IO Response
handleMe tv req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just uid -> do
      mu <- atomically $ do st <- readTVar tv; pure (M.lookup uid (users st))
      case mu of
        Nothing -> pure $ jsonErr status401 "Authentication required"
        Just (UserRec u _) -> pure $ jsonOk u

handlePassword :: TVar Store -> Request -> IO Response
handlePassword tv req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just uid -> do
      b <- readBody req
      case A.eitherDecode b of
        Left _ -> pure $ jsonErr status400 "Password too short"
        Right (ChangePassReq old newp) ->
          if T.length newp < 8 then pure $ jsonErr status400 "Password too short" else do
            ok <- atomically $ do
              st <- readTVar tv
              case M.lookup uid (users st) of
                Nothing -> pure False
                Just (UserRec u pass) -> if pass == old
                  then do
                    writeTVar tv st { users = M.insert uid (UserRec u newp) (users st) }
                    pure True
                  else pure False
            if ok then pure $ json status200 (A.object [])
                  else pure $ jsonErr status401 "Invalid credentials"

handleTodosList :: TVar Store -> Request -> IO Response
handleTodosList tv req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just uid -> do
      ts <- atomically $ do
        st <- readTVar tv
        let ids = fromMaybe [] (M.lookup uid (userTodos st))
            ts' = map (\i -> todos st M.! i) ids
        pure ts'
      pure $ jsonOk ts

handleTodosCreate :: TVar Store -> Request -> IO Response
handleTodosCreate tv req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just uid -> do
      b <- readBody req
      case A.eitherDecode b of
        Left _ -> pure $ jsonErr status400 "Title is required"
        Right (NewTodoReq t md) ->
          if T.strip t == "" then pure $ jsonErr status400 "Title is required" else do
            now <- getCurrentTime
            todo <- atomically $ do
              st <- readTVar tv
              let tid = nextTodoId st
                  td = Todo tid t (fromMaybe "" md) False now now uid
                  st' = st { todos = M.insert tid td (todos st)
                           , userTodos = M.insertWith (\new old -> old ++ new) uid [tid] (userTodos st)
                           , nextTodoId = tid + 1 }
              writeTVar tv st'
              pure td
            pure $ responseLBS status201 [(hContentType, "application/json")] (A.encode todo)

handleTodoGet :: TVar Store -> Int -> Request -> IO Response
handleTodoGet tv tid req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just uid -> do
      mtd <- atomically $ do st <- readTVar tv; pure (M.lookup tid (todos st))
      case mtd of
        Just td | ownerId td == uid -> pure $ jsonOk td
        _ -> pure $ jsonErr status404 "Todo not found"

handleTodoUpdate :: TVar Store -> Int -> Request -> IO Response
handleTodoUpdate tv tid req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just uid -> do
      b <- readBody req
      case A.eitherDecode b of
        Left _ -> pure $ jsonErr status400 "Title is required"
        Right (UpdateTodoReq mt md mc) ->
          if maybe False (\t -> T.strip t == "") mt then pure $ jsonErr status400 "Title is required" else do
            now <- getCurrentTime
            mres <- atomically $ do
              st <- readTVar tv
              case M.lookup tid (todos st) of
                Nothing -> pure Nothing
                Just td -> if ownerId td /= uid then pure Nothing else do
                  let td' = td { title = fromMaybe (title td) mt
                               , description = fromMaybe (description td) md
                               , completed = fromMaybe (completed td) mc
                               , updatedAt = now }
                  writeTVar tv st { todos = M.insert tid td' (todos st) }
                  pure (Just td')
            case mres of
              Nothing -> pure $ jsonErr status404 "Todo not found"
              Just td' -> pure $ jsonOk td'

handleTodoDelete :: TVar Store -> Int -> Request -> IO Response
handleTodoDelete tv tid req = do
  mauth <- getAuth tv req
  case mauth of
    Nothing -> pure $ jsonErr status401 "Authentication required"
    Just uid -> do
      ok <- atomically $ do
        st <- readTVar tv
        case M.lookup tid (todos st) of
          Nothing -> pure False
          Just td -> if ownerId td /= uid then pure False else do
            let ts' = M.delete tid (todos st)
                ids = fromMaybe [] (M.lookup uid (userTodos st))
                ids' = filter (/= tid) ids
            writeTVar tv st { todos = ts', userTodos = M.insert uid ids' (userTodos st) }
            pure True
      if ok then pure $ noBody status204 else pure $ jsonErr status404 "Todo not found"

-- Router
app :: TVar Store -> Application
app tv req respond = do
  let method = requestMethod req
      p = pathInfo req
  case (method, p) of
    ("POST", ["register"]) -> handleRegister tv req >>= respond
    ("POST", ["login"])    -> handleLogin tv req >>= respond
    ("POST", ["logout"])   -> handleLogout tv req >>= respond
    ("GET" , ["me"])       -> handleMe tv req >>= respond
    ("PUT" , ["password"]) -> handlePassword tv req >>= respond
    ("GET" , ["todos"])    -> handleTodosList tv req >>= respond
    ("POST", ["todos"])    -> handleTodosCreate tv req >>= respond
    ("GET" , ["todos", tidTxt]) -> case readInt tidTxt of
                                      Nothing  -> respond $ jsonErr status404 "Todo not found"
                                      Just tid -> handleTodoGet tv tid req >>= respond
    ("PUT" , ["todos", tidTxt]) -> case readInt tidTxt of
                                      Nothing  -> respond $ jsonErr status404 "Todo not found"
                                      Just tid -> handleTodoUpdate tv tid req >>= respond
    ("DELETE", ["todos", tidTxt]) -> case readInt tidTxt of
                                      Nothing  -> respond $ jsonErr status404 "Todo not found"
                                      Just tid -> handleTodoDelete tv tid req >>= respond
    _ -> respond $ jsonErr status404 "Not found"

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack t) of
  [(x,"")] -> Just x
  _         -> Nothing

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
        ("--port":p:_) -> read p
        _               -> 3000
  tv <- newTVarIO defaultStore
  let settings = setHost "0.0.0.0" $ setPort port defaultSettings
  runSettings settings (app tv)
