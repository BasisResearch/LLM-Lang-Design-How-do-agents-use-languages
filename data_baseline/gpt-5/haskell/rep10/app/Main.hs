{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Network.Wai
import           Network.Wai.Handler.Warp (runSettings, defaultSettings, setPort, setHost)
import           Network.HTTP.Types
import           Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.:?), withObject, object, (.=))
import qualified Data.Aeson as Aeson
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import           Data.Time.Clock
import           Data.Time.Format
import           System.Environment (getArgs)
import           Control.Concurrent.STM
import           Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.List (sortOn)
import           Web.Cookie (parseCookies, SetCookie(..), defaultSetCookie, renderSetCookie)
import qualified Data.UUID.V4 as UUIDv4
import qualified Data.UUID as UUID
import           Data.Char (isAlphaNum)
import           Data.ByteString.Builder (toLazyByteString)

-- Data types

data User = User
  { uId       :: Int
  , uUsername :: Text
  , uPassword :: Text
  } deriving (Show, Eq)

userJSON :: User -> Aeson.Value
userJSON u = object ["id" .= uId u, "username" .= uUsername u]

data Todo = Todo
  { tId          :: Int
  , tOwnerId     :: Int
  , tTitle       :: Text
  , tDescription :: Text
  , tCompleted   :: Bool
  , tCreatedAt   :: Text
  , tUpdatedAt   :: Text
  } deriving (Show, Eq)

todoJSON :: Todo -> Aeson.Value
todoJSON t = object
  [ "id" .= tId t
  , "title" .= tTitle t
  , "description" .= tDescription t
  , "completed" .= tCompleted t
  , "created_at" .= tCreatedAt t
  , "updated_at" .= tUpdatedAt t
  ]

-- Request bodies

data RegisterReq = RegisterReq { rrUsername :: Text, rrPassword :: Text } deriving (Show)
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq <$> o .: "username" <*> o .: "password"

data LoginReq = LoginReq { lrUsername :: Text, lrPassword :: Text } deriving (Show)
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq <$> o .: "username" <*> o .: "password"

data PasswordReq = PasswordReq { prOld :: Text, prNew :: Text } deriving (Show)
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \o -> PasswordReq <$> o .: "old_password" <*> o .: "new_password"

data CreateTodoReq = CreateTodoReq { ctrTitle :: Text, ctrDescription :: Maybe Text } deriving (Show)
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \o -> CreateTodoReq <$> o .: "title" <*> o .:? "description"

data UpdateTodoReq = UpdateTodoReq { utrTitle :: Maybe Text, utrDescription :: Maybe Text, utrCompleted :: Maybe Bool } deriving (Show)
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> UpdateTodoReq <$> o .:? "title" <*> o .:? "description" <*> o .:? "completed"

-- State

data AppState = AppState
  { stNextUserId  :: !Int
  , stUsersById   :: !(IntMap User)
  , stUsersByName :: !(Map Text Int)
  , stNextTodoId  :: !Int
  , stTodosById   :: !(IntMap Todo)
  , stSessions    :: !(Map Text Int) -- token -> userId
  }

emptyState :: AppState
emptyState = AppState 1 IntMap.empty Map.empty 1 IntMap.empty Map.empty

-- Helpers
jsonError :: Status -> Text -> Response
jsonError code msg = responseLBS code [(hContentType, "application/json")] (Aeson.encode (object ["error" .= msg]))

jsonOk :: Status -> Aeson.Value -> Response
jsonOk code val = responseLBS code [(hContentType, "application/json")] (Aeson.encode val)

nowTimestamp :: IO Text
nowTimestamp = do
  t <- getCurrentTime
  let s = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t
  return (T.pack s)

validateUsername :: Text -> Bool
validateUsername name =
  let l = T.length name
      okLen = l >= 3 && l <= 50
      okChars = T.all (\c -> isAlphaNum c || c == '_') name
  in okLen && okChars

validatePassword :: Text -> Bool
validatePassword p = T.length p >= 8

readBody :: Request -> IO BL.ByteString
readBody req = do
  let loop acc = do
        chunk <- getRequestBodyChunk req
        if BS.null chunk then return (reverse acc) else loop (chunk:acc)
  chunks <- loop []
  return (BL.fromChunks chunks)

parseJsonBody :: FromJSON a => Request -> IO (Either Text a)
parseJsonBody req = do
  b <- readBody req
  case Aeson.eitherDecode b of
    Left _  -> return (Left (T.pack "Invalid JSON"))
    Right v -> return (Right v)

-- Cookie/session
getSessionToken :: Request -> Maybe Text
getSessionToken req = do
  raw <- lookup hCookie (requestHeaders req)
  let pairs = parseCookies raw
  val <- lookup "session_id" pairs
  return (TE.decodeUtf8 val)

setSessionCookieHeader :: Text -> (HeaderName, BS.ByteString)
setSessionCookieHeader tok =
  let sc = defaultSetCookie { setCookieName = "session_id"
                            , setCookieValue = TE.encodeUtf8 tok
                            , setCookiePath = Just "/"
                            , setCookieHttpOnly = True
                            }
      rendered = toLazyByteString (renderSetCookie sc)
  in ("Set-Cookie", BL.toStrict rendered)

-- Routing helpers
notFoundJSON :: Response
notFoundJSON = jsonError status404 "Not found"

-- Main application
app :: TVar AppState -> Application
app stVar req respond = do
  let method = requestMethod req
      path = pathInfo req
  case (method, path) of
    ("POST", ["register"]) -> do
      e <- parseJsonBody req
      case e of
        Left _ -> respond (jsonError status400 "Invalid JSON")
        Right (RegisterReq uname pwd) -> do
          if not (validateUsername uname)
            then respond (jsonError status400 "Invalid username")
            else if not (validatePassword pwd)
              then respond (jsonError status400 "Password too short")
              else do
                res <- atomically $ do
                  st <- readTVar stVar
                  if Map.member uname (stUsersByName st)
                    then return (Left ())
                    else do
                      let newId = stNextUserId st
                          user = User newId uname pwd
                          st' = st { stNextUserId = newId + 1
                                   , stUsersById = IntMap.insert newId user (stUsersById st)
                                   , stUsersByName = Map.insert uname newId (stUsersByName st)
                                   }
                      writeTVar stVar st'
                      return (Right user)
                case res of
                  Left _    -> respond (jsonError status409 "Username already exists")
                  Right usr -> respond (jsonOk status201 (userJSON usr))

    ("POST", ["login"]) -> do
      e <- parseJsonBody req
      case e of
        Left _ -> respond (jsonError status400 "Invalid JSON")
        Right (LoginReq uname pwd) -> do
          mUser <- atomically $ do
            st <- readTVar stVar
            case Map.lookup uname (stUsersByName st) of
              Nothing  -> return Nothing
              Just uid -> return (IntMap.lookup uid (stUsersById st))
          case mUser of
            Nothing -> respond (jsonError status401 "Invalid credentials")
            Just u -> if uPassword u /= pwd
                        then respond (jsonError status401 "Invalid credentials")
                        else do
                          uuid <- UUIDv4.nextRandom
                          let tok = UUID.toText uuid
                          atomically $ do
                            st <- readTVar stVar
                            let st' = st { stSessions = Map.insert tok (uId u) (stSessions st) }
                            writeTVar stVar st'
                          let headers = [(hContentType, "application/json"), setSessionCookieHeader tok]
                          respond $ responseLBS status200 headers (Aeson.encode (userJSON u))

    ("POST", ["logout"]) -> do
      case getSessionToken req of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just tok -> do
          ok <- atomically $ do
            st <- readTVar stVar
            if Map.member tok (stSessions st)
              then do
                let st' = st { stSessions = Map.delete tok (stSessions st) }
                writeTVar stVar st'
                return True
              else return False
          if ok
            then respond (jsonOk status200 (object []))
            else respond (jsonError status401 "Authentication required")

    ("GET", ["me"]) -> do
      mUser <- atomically $ currentUser stVar (getSessionToken req)
      case mUser of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just u  -> respond (jsonOk status200 (userJSON u))

    ("PUT", ["password"]) -> do
      mUser <- atomically $ currentUser stVar (getSessionToken req)
      case mUser of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just u  -> do
          e <- parseJsonBody req
          case e of
            Left _ -> respond (jsonError status400 "Invalid JSON")
            Right (PasswordReq old newp) ->
              if uPassword u /= old
                then respond (jsonError status401 "Invalid credentials")
                else if not (validatePassword newp)
                  then respond (jsonError status400 "Password too short")
                  else do
                    atomically $ do
                      st <- readTVar stVar
                      let uid = uId u
                          Just u0 = IntMap.lookup uid (stUsersById st)
                          u' = u0 { uPassword = newp }
                          st' = st { stUsersById = IntMap.insert uid u' (stUsersById st) }
                      writeTVar stVar st'
                    respond (jsonOk status200 (object []))

    ("GET", ["todos"]) -> do
      mUser <- atomically $ currentUser stVar (getSessionToken req)
      case mUser of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just u  -> do
          ts <- atomically $ do
            st <- readTVar stVar
            let ts0 = filter ((== uId u) . tOwnerId) (IntMap.elems (stTodosById st))
            return (sortOn tId ts0)
          respond (jsonOk status200 (Aeson.toJSON (map todoJSON ts)))

    ("POST", ["todos"]) -> do
      mUser <- atomically $ currentUser stVar (getSessionToken req)
      case mUser of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just u  -> do
          e <- parseJsonBody req
          case e of
            Left _ -> respond (jsonError status400 "Invalid JSON")
            Right (CreateTodoReq title mdesc) ->
              if T.strip title == ""
                then respond (jsonError status400 "Title is required")
                else do
                  now <- nowTimestamp
                  todo <- atomically $ do
                    st <- readTVar stVar
                    let newId = stNextTodoId st
                        todo = Todo newId (uId u) title (maybe "" id mdesc) False now now
                        st' = st { stNextTodoId = newId + 1
                                 , stTodosById = IntMap.insert newId todo (stTodosById st)
                                 }
                    writeTVar stVar st'
                    return todo
                  respond (jsonOk status201 (todoJSON todo))

    ("GET", ["todos", tidTxt]) -> do
      mUser <- atomically $ currentUser stVar (getSessionToken req)
      case mUser of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just u  -> case readInt tidTxt of
          Nothing  -> respond (jsonError status404 "Todo not found")
          Just tid -> do
            mt <- atomically $ do
              st <- readTVar stVar
              return (IntMap.lookup tid (stTodosById st))
            case mt of
              Nothing -> respond (jsonError status404 "Todo not found")
              Just t  -> if tOwnerId t /= uId u
                           then respond (jsonError status404 "Todo not found")
                           else respond (jsonOk status200 (todoJSON t))

    ("PUT", ["todos", tidTxt]) -> do
      mUser <- atomically $ currentUser stVar (getSessionToken req)
      case mUser of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just u  -> case readInt tidTxt of
          Nothing  -> respond (jsonError status404 "Todo not found")
          Just tid -> do
            e <- parseJsonBody req
            case e of
              Left _ -> respond (jsonError status400 "Invalid JSON")
              Right (UpdateTodoReq mt md mc) -> do
                if maybe False (\x -> T.strip x == "") mt
                  then respond (jsonError status400 "Title is required")
                  else do
                    now <- nowTimestamp
                    res <- atomically $ do
                      st <- readTVar stVar
                      case IntMap.lookup tid (stTodosById st) of
                        Nothing -> return Nothing
                        Just t -> if tOwnerId t /= uId u
                                    then return Nothing
                                    else do
                                      let t' = t { tTitle = maybe (tTitle t) id mt
                                                 , tDescription = maybe (tDescription t) id md
                                                 , tCompleted = maybe (tCompleted t) id mc
                                                 , tUpdatedAt = now
                                                 }
                                          st' = st { stTodosById = IntMap.insert tid t' (stTodosById st) }
                                      writeTVar stVar st'
                                      return (Just t')
                    case res of
                      Nothing -> respond (jsonError status404 "Todo not found")
                      Just t' -> respond (jsonOk status200 (todoJSON t'))

    ("DELETE", ["todos", tidTxt]) -> do
      mUser <- atomically $ currentUser stVar (getSessionToken req)
      case mUser of
        Nothing -> respond (jsonError status401 "Authentication required")
        Just u  -> case readInt tidTxt of
          Nothing  -> respond (jsonError status404 "Todo not found")
          Just tid -> do
            ok <- atomically $ do
              st <- readTVar stVar
              case IntMap.lookup tid (stTodosById st) of
                Nothing -> return False
                Just t -> if tOwnerId t /= uId u
                            then return False
                            else do
                              let st' = st { stTodosById = IntMap.delete tid (stTodosById st) }
                              writeTVar stVar st'
                              return True
            if ok
              then respond (responseLBS status204 [] BL.empty)
              else respond (jsonError status404 "Todo not found")

    _ -> respond notFoundJSON

-- Helpers
currentUser :: TVar AppState -> Maybe Text -> STM (Maybe User)
currentUser stVar mTok = do
  case mTok of
    Nothing -> return Nothing
    Just tok -> do
      st <- readTVar stVar
      case Map.lookup tok (stSessions st) of
        Nothing  -> return Nothing
        Just uid -> return (IntMap.lookup uid (stUsersById st))

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack t) of
  [(n, "")] -> Just n
  _          -> Nothing

-- Main
parsePort :: [String] -> Int -> Int
parsePort ("--port":pStr:rest) _ = case reads pStr of
  [(p, "")] -> p
  _          -> parsePort rest 3000
parsePort (_:rest) def = parsePort rest def
parsePort [] def = def

main :: IO ()
main = do
  args <- getArgs
  let port = parsePort args 3000
  stVar <- atomically $ newTVar emptyState
  let settings = setPort port $ setHost "0.0.0.0" defaultSettings
  runSettings settings (app stVar)
