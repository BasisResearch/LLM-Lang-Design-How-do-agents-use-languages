{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Monad (when)
import           Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.:?), withObject, object, (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as LBS
import           Data.IORef
import qualified Data.List as L
import qualified Data.Map.Strict as M
import           Data.Maybe (fromMaybe)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Data.Time (getCurrentTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           Data.UUID (toText)
import           Data.UUID.V4 (nextRandom)
import           Network.HTTP.Types (Status, methodGet, methodPost, methodPut, methodDelete, status200, status201, status204, status400, status401, status404, status409, hContentType, hCookie, Header)
import           Network.Wai
import           Network.Wai.Handler.Warp (runSettings, setHost, setPort, defaultSettings)
import           System.Environment (getArgs)
import           Text.Read (readMaybe)
import           Web.Cookie (parseCookies)

-- Data types

data User = User { uId :: Int, uName :: Text, uPass :: Text } deriving (Show, Eq)

instance ToJSON User where
  toJSON (User i n _p) = object ["id" .= i, "username" .= n]

userPublic :: User -> A.Value
userPublic (User i n _p) = object ["id" .= i, "username" .= n]

-- Todo

data Todo = Todo
  { tId :: Int
  , tUserId :: Int
  , tTitle :: Text
  , tDesc :: Text
  , tCompleted :: Bool
  , tCreated :: Text
  , tUpdated :: Text
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON (Todo i _ title desc comp c u) = object
    [ "id" .= i
    , "title" .= title
    , "description" .= desc
    , "completed" .= comp
    , "created_at" .= c
    , "updated_at" .= u
    ]

-- Request bodies

data RegisterReq = RegisterReq { rUsername :: Text, rPassword :: Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq <$> o .: "username" <*> o .: "password"

data LoginReq = LoginReq { lUsername :: Text, lPassword :: Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq <$> o .: "username" <*> o .: "password"

data PasswordReq = PasswordReq { oldPassword :: Text, newPassword :: Text }
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \o -> PasswordReq <$> o .: "old_password" <*> o .: "new_password"

data CreateTodoReq = CreateTodoReq { cTitle :: Text, cDesc :: Maybe Text }
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \o -> CreateTodoReq <$> o .: "title" <*> o .:? "description"

data UpdateTodoReq = UpdateTodoReq { uTitle :: Maybe Text, uDesc :: Maybe Text, uCompleted :: Maybe Bool }
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> UpdateTodoReq <$> o .:? "title" <*> o .:? "description" <*> o .:? "completed"

-- App state

data AppState = AppState
  { users :: IORef (M.Map Int User)
  , usernames :: IORef (M.Map Text Int)
  , nextUserId :: IORef Int
  , sessions :: IORef (M.Map Text Int)
  , todos :: IORef (M.Map Int Todo)
  , nextTodoId :: IORef Int
  }

-- Utilities

iso8601Z :: IO Text
iso8601Z = do
  now <- getCurrentTime
  pure . T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

validUsername :: Text -> Bool
validUsername t =
  let len = T.length t
      allowed = T.all (\c -> c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) t
  in len >= 3 && len <= 50 && allowed

strictBody :: Request -> IO LBS.ByteString
strictBody req = go mempty
  where
    go acc = do
      chunk <- requestBody req
      if BS.null chunk then pure (LBS.fromChunks (reverse acc)) else go (chunk:acc)

jsonResp :: Status -> A.Value -> Response
jsonResp st val = responseLBS st [(hContentType, "application/json")] (A.encode val)

jsonErr :: Status -> Text -> Response
jsonErr st msg = jsonResp st (object ["error" .= msg])

parseJsonBody :: FromJSON a => Request -> IO (Either Text a)
parseJsonBody req = do
  b <- strictBody req
  pure $ case A.eitherDecode b of
    Left _  -> Left "Invalid JSON"
    Right v -> Right v

getSessionToken :: Request -> Maybe Text
getSessionToken req = do
  cookieHeader <- lookup hCookie (requestHeaders req)
  let cookies = parseCookies cookieHeader
  T.pack . C8.unpack <$> lookup "session_id" cookies

requireAuth :: AppState -> Request -> IO (Either Response User)
requireAuth st req = do
  case getSessionToken req of
    Nothing -> pure $ Left (jsonErr status401 "Authentication required")
    Just tok -> do
      sess <- readIORef (sessions st)
      case M.lookup tok sess of
        Nothing -> pure $ Left (jsonErr status401 "Authentication required")
        Just uid -> do
          us <- readIORef (users st)
          case M.lookup uid us of
            Nothing -> pure $ Left (jsonErr status401 "Authentication required")
            Just u  -> pure $ Right u

-- Routing

app :: AppState -> Application
app st req respond = do
  let method = requestMethod req
      path = pathInfo req
  case (method, path) of
    (m, ["register"]) | m == methodPost -> do
      ej <- parseJsonBody req
      case ej of
        Left e -> respond (jsonErr status400 e)
        Right (RegisterReq uname pwd) -> do
          if not (validUsername uname) then respond (jsonErr status400 "Invalid username")
          else if T.length pwd < 8 then respond (jsonErr status400 "Password too short")
          else do
            taken <- M.member uname <$> readIORef (usernames st)
            if taken then respond (jsonErr status409 "Username already exists")
            else do
              uid <- atomicModifyIORef' (nextUserId st) (\i -> (i+1, i))
              let user = User uid uname pwd
              modifyIORef' (users st) (M.insert uid user)
              modifyIORef' (usernames st) (M.insert uname uid)
              respond (jsonResp status201 (userPublic user))

    (m, ["login"]) | m == methodPost -> do
      ej <- parseJsonBody req
      case ej of
        Left e -> respond (jsonErr status400 e)
        Right (LoginReq uname pwd) -> do
          mu <- M.lookup uname <$> readIORef (usernames st)
          case mu of
            Nothing -> respond (jsonErr status401 "Invalid credentials")
            Just uid -> do
              us <- readIORef (users st)
              case M.lookup uid us of
                Just (User _ _ pass) | pass == pwd -> do
                  tok <- toText <$> nextRandom
                  modifyIORef' (sessions st) (M.insert tok uid)
                  let cookie = TE.encodeUtf8 (T.concat ["session_id=", tok, "; Path=/; HttpOnly"]) :: BS.ByteString
                      headers = [(hContentType, "application/json"), ("Set-Cookie", cookie)] :: [Header]
                      body = A.encode (object ["id" .= uid, "username" .= uname])
                  respond (responseLBS status200 headers body)
                _ -> respond (jsonErr status401 "Invalid credentials")

    (m, ["logout"]) | m == methodPost -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right _u -> do
          case getSessionToken req of
            Nothing -> respond (jsonErr status401 "Authentication required")
            Just tok -> do
              modifyIORef' (sessions st) (M.delete tok)
              respond (jsonResp status200 (object []))

    (m, ["me"]) | m == methodGet -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right u -> respond (jsonResp status200 (userPublic u))

    (m, ["password"]) | m == methodPut -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right (User uid uname curPass) -> do
          ej <- parseJsonBody req
          case ej of
            Left e -> respond (jsonErr status400 e)
            Right (PasswordReq old new) ->
              if old /= curPass then respond (jsonErr status401 "Invalid credentials")
              else if T.length new < 8 then respond (jsonErr status400 "Password too short")
              else do
                modifyIORef' (users st) (M.adjust (\(User i n _) -> User i n new) uid)
                respond (jsonResp status200 (object []))

    (m, ["todos"]) | m == methodGet -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right (User uid _ _) -> do
          ts <- readIORef (todos st)
          let userTodos = L.sortOn tId [ t | t <- M.elems ts, tUserId t == uid ]
          respond (jsonResp status200 (A.toJSON userTodos))

    (m, ["todos"]) | m == methodPost -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right (User uid _ _) -> do
          ej <- parseJsonBody req
          case ej of
            Left e -> respond (jsonErr status400 e)
            Right (CreateTodoReq title md) ->
              if T.strip title == "" then respond (jsonErr status400 "Title is required")
              else do
                now <- iso8601Z
                tid <- atomicModifyIORef' (nextTodoId st) (\i -> (i+1, i))
                let todo = Todo tid uid title (fromMaybe "" md) False now now
                modifyIORef' (todos st) (M.insert tid todo)
                respond (jsonResp status201 (A.toJSON todo))

    (m, ["todos", tidTxt]) | m == methodGet -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right (User uid _ _) -> do
          case readMaybe (T.unpack tidTxt) :: Maybe Int of
            Nothing -> respond (jsonErr status404 "Todo not found")
            Just tid -> do
              ts <- readIORef (todos st)
              case M.lookup tid ts of
                Nothing -> respond (jsonErr status404 "Todo not found")
                Just t -> if tUserId t /= uid then respond (jsonErr status404 "Todo not found")
                          else respond (jsonResp status200 (A.toJSON t))

    (m, ["todos", tidTxt]) | m == methodPut -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right (User uid _ _) -> do
          case readMaybe (T.unpack tidTxt) :: Maybe Int of
            Nothing -> respond (jsonErr status404 "Todo not found")
            Just tid -> do
              ej <- parseJsonBody req
              case ej of
                Left e -> respond (jsonErr status400 e)
                Right (UpdateTodoReq mt md mc) -> do
                  ts <- readIORef (todos st)
                  case M.lookup tid ts of
                    Nothing -> respond (jsonErr status404 "Todo not found")
                    Just t -> if tUserId t /= uid then respond (jsonErr status404 "Todo not found")
                              else case mt of
                                Just ttitle | T.strip ttitle == "" -> respond (jsonErr status400 "Title is required")
                                _ -> do
                                  now <- iso8601Z
                                  let t' = t { tTitle = fromMaybe (tTitle t) mt
                                             , tDesc = fromMaybe (tDesc t) md
                                             , tCompleted = fromMaybe (tCompleted t) mc
                                             , tUpdated = now
                                             }
                                  modifyIORef' (todos st) (M.insert tid t')
                                  respond (jsonResp status200 (A.toJSON t'))

    (m, ["todos", tidTxt]) | m == methodDelete -> do
      au <- requireAuth st req
      case au of
        Left r -> respond r
        Right (User uid _ _) -> do
          case readMaybe (T.unpack tidTxt) :: Maybe Int of
            Nothing -> respond (jsonErr status404 "Todo not found")
            Just tid -> do
              ts <- readIORef (todos st)
              case M.lookup tid ts of
                Nothing -> respond (jsonErr status404 "Todo not found")
                Just t -> if tUserId t /= uid then respond (jsonErr status404 "Todo not found")
                          else do
                            modifyIORef' (todos st) (M.delete tid)
                            respond (responseLBS status204 [] "")

    _ -> respond (jsonErr status404 "Not found")

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
        ("--port":p:_) -> read p
        _               -> 3000 :: Int
  usersRef <- newIORef M.empty
  usernamesRef <- newIORef M.empty
  nextUserIdRef <- newIORef 1
  sessionsRef <- newIORef M.empty
  todosRef <- newIORef M.empty
  nextTodoIdRef <- newIORef 1
  let st = AppState usersRef usernamesRef nextUserIdRef sessionsRef todosRef nextTodoIdRef
      settings = setHost "0.0.0.0" . setPort port $ defaultSettings
  runSettings settings (app st)
