{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Web.Scotty
import           Network.Wai (Middleware, Request, pathInfo)
import qualified Network.Wai as Wai
import           Network.Wai.Handler.Warp (defaultSettings, setPort, setHost, runSettings)
import           Network.Wai.Middleware.RequestLogger (logStdoutDev)
import           Network.HTTP.Types (status201, status204, status400, status401, status404, hContentType)
import           Data.Aeson (ToJSON(..), FromJSON(..), (.:), (.:?), withObject, object, (.=), eitherDecode)
import qualified Data.Text as T
import           Data.Text (Text)
import qualified Data.Text.Lazy as TL
import qualified Data.Map.Strict as M
import           Data.Time
import           Control.Concurrent.STM
import           Control.Monad.IO.Class (liftIO)
import           System.Environment (getArgs)
import           Data.UUID (toText)
import           Data.UUID.V4 (nextRandom)
import           Text.Read (readMaybe)
import           Data.List (sortOn)
import           Data.Char (isAlphaNum)

-- Data types

data User = User
  { userId   :: Int
  , username :: Text
  , password :: Text
  } deriving (Show, Eq)

instance ToJSON User where
  toJSON (User uid un _) = object ["id" .= uid, "username" .= un]

data Todo = Todo
  { todoId      :: Int
  , ownerId     :: Int
  , title       :: Text
  , description :: Text
  , completed   :: Bool
  , createdAt   :: Text
  , updatedAt   :: Text
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON (Todo i _ t d c ca ua) = object
    [ "id" .= i
    , "title" .= t
    , "description" .= d
    , "completed" .= c
    , "created_at" .= ca
    , "updated_at" .= ua
    ]

-- In-memory storage

data AppState = AppState
  { nextUserId :: TVar Int
  , users      :: TVar (M.Map Int User)
  , usersByName :: TVar (M.Map Text Int)
  , nextTodoId :: TVar Int
  , todos      :: TVar (M.Map Int Todo)
  , sessions   :: TVar (M.Map Text Int) -- token -> userId
  }

newState :: IO AppState
newState = atomically $ do
  nu <- newTVar 1
  us <- newTVar M.empty
  ub <- newTVar M.empty
  nt <- newTVar 1
  ts <- newTVar M.empty
  ss <- newTVar M.empty
  return $ AppState nu us ub nt ts ss

-- Helpers

isoNow :: IO Text
isoNow = do
  t <- getCurrentTime
  let t' = UTCTime (utctDay t) (secondsToDiffTime $ floor (utctDayTime t))
  return $ T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t')

jsonError :: Int -> Text -> ActionM a
jsonError code msg = do
  status (toEnum code)
  setHeader "Content-Type" "application/json"
  json $ object ["error" .= msg]
  finish

requireAuth :: AppState -> ActionM User
requireAuth st = do
  cs <- header "Cookie"
  case parseCookie =<< fmap TL.toStrict cs of
    Just token -> do
      mu <- liftIO . atomically $ do
        sess <- readTVar (sessions st)
        case M.lookup token sess of
          Nothing -> return Nothing
          Just uid -> do
            us <- readTVar (users st)
            return (M.lookup uid us)
      case mu of
        Just u -> return u
        Nothing -> unauthorized
    Nothing -> unauthorized
  where
    unauthorized = jsonError 401 "Authentication required"

parseCookie :: Text -> Maybe Text
parseCookie txt =
  let parts = map T.strip (T.splitOn ";" txt)
      kvs = map (\p -> let (k,v) = T.breakOn "=" p in (k, T.drop 1 v)) parts
  in lookup "session_id" kvs

-- Validation helpers

validUsername :: Text -> Bool
validUsername t = let l = T.length t in l >= 3 && l <= 50 && T.all (\c -> isAlphaNum c || c == '_') t

-- JSON bodies

data RegisterReq = RegisterReq { rrUsername :: Text, rrPassword :: Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq <$> o .: "username" <*> o .: "password"

data LoginReq = LoginReq { lrUsername :: Text, lrPassword :: Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq <$> o .: "username" <*> o .: "password"

-- Password change

data PassReq = PassReq { oldPassword :: Text, newPassword :: Text }
instance FromJSON PassReq where
  parseJSON = withObject "PassReq" $ \o -> PassReq <$> o .: "old_password" <*> o .: "new_password"

-- Todo create

data TodoCreateReq = TodoCreateReq { tcrTitle :: Text, tcrDesc :: Maybe Text }
instance FromJSON TodoCreateReq where
  parseJSON = withObject "TodoCreateReq" $ \o -> TodoCreateReq <$> o .: "title" <*> o .:? "description"

-- Todo update (partial)

data TodoUpdateReq = TodoUpdateReq { turTitle :: Maybe Text, turDesc :: Maybe Text, turCompleted :: Maybe Bool }
instance FromJSON TodoUpdateReq where
  parseJSON = withObject "TodoUpdateReq" $ \o -> TodoUpdateReq <$> o .:? "title" <*> o .:? "description" <*> o .:? "completed"

-- Helpers to read JSON safely
parseJsonBody :: FromJSON a => ActionM a
parseJsonBody = do
  b <- body
  case eitherDecode b of
    Left _ -> jsonError 400 "Invalid JSON body"
    Right v -> return v

-- Get ID from request path (for "/todos/:id" routes)
getIdFromRequest :: ActionM Int
getIdFromRequest = do
  req <- request
  let segs = pathInfo req
  case segs of
    ["todos", tidTxt] ->
      case readMaybe (T.unpack tidTxt) of
        Just n -> return n
        Nothing -> jsonError 404 "Todo not found"
    _ -> jsonError 404 "Todo not found"

-- Application routes
appRoutes :: AppState -> ScottyM ()
appRoutes st = do
  middleware setJsonContentType
  middleware logStdoutDev

  -- POST /register
  post "/register" $ do
    setHeader "Content-Type" "application/json"
    RegisterReq un pw <- parseJsonBody
    if not (validUsername un)
      then jsonError 400 "Invalid username"
      else if T.length pw < 8
        then jsonError 400 "Password too short"
        else do
          res <- liftIO . atomically $ do
            ub <- readTVar (usersByName st)
            if M.member un ub
              then return (Left (409 :: Int, "Username already exists" :: Text))
              else do
                uid <- readTVar (nextUserId st)
                let u = User uid un pw
                modifyTVar' (users st) (M.insert uid u)
                modifyTVar' (usersByName st) (M.insert un uid)
                writeTVar (nextUserId st) (uid + 1)
                return (Right u)
          case res of
            Left (c,msg) -> jsonError c msg
            Right u -> do
              status status201
              json u

  -- POST /login
  post "/login" $ do
    setHeader "Content-Type" "application/json"
    LoginReq un pw <- parseJsonBody
    mu <- liftIO . atomically $ do
      ub <- readTVar (usersByName st)
      case M.lookup un ub of
        Nothing -> return Nothing
        Just uid -> do
          us <- readTVar (users st)
          return (M.lookup uid us)
    case mu of
      Just u | password u == pw -> do
        tok <- liftIO $ toText <$> nextRandom
        liftIO . atomically $ modifyTVar' (sessions st) (M.insert tok (userId u))
        addHeader "Set-Cookie" (TL.fromStrict (T.concat ["session_id=", tok, "; Path=/; HttpOnly"]))
        json u
      _ -> jsonError 401 "Invalid credentials"

  -- POST /logout
  post "/logout" $ do
    _u <- requireAuth st
    mc <- header "Cookie"
    case parseCookie =<< fmap TL.toStrict mc of
      Just tok -> liftIO . atomically $ modifyTVar' (sessions st) (M.delete tok)
      Nothing -> return ()
    setHeader "Content-Type" "application/json"
    json (object [])

  -- GET /me
  get "/me" $ do
    u <- requireAuth st
    setHeader "Content-Type" "application/json"
    json u

  -- PUT /password
  put "/password" $ do
    u <- requireAuth st
    setHeader "Content-Type" "application/json"
    PassReq op np <- parseJsonBody
    if T.length np < 8
      then jsonError 400 "Password too short"
      else if op /= password u
        then jsonError 401 "Invalid credentials"
        else do
          let uid = userId u
          liftIO . atomically $ modifyTVar' (users st) (M.adjust (\usr -> usr { password = np }) uid)
          json (object [])

  -- GET /todos
  get "/todos" $ do
    u <- requireAuth st
    setHeader "Content-Type" "application/json"
    ts <- liftIO . atomically $ do
      m <- readTVar (todos st)
      let own = filter ((== userId u) . ownerId) (M.elems m)
      return (sortOn todoId own)
    json ts

  -- POST /todos
  post "/todos" $ do
    u <- requireAuth st
    setHeader "Content-Type" "application/json"
    TodoCreateReq t md <- parseJsonBody
    if T.strip t == ""
      then jsonError 400 "Title is required"
      else do
        now <- liftIO isoNow
        todo <- liftIO . atomically $ do
          tid <- readTVar (nextTodoId st)
          let td = Todo tid (userId u) t (maybe "" id md) False now now
          modifyTVar' (todos st) (M.insert tid td)
          writeTVar (nextTodoId st) (tid + 1)
          return td
        status status201
        json todo

  -- GET /todos/:id
  get "/todos/:id" $ do
    u <- requireAuth st
    setHeader "Content-Type" "application/json"
    sid <- getIdFromRequest
    mt <- liftIO . atomically $ do
      m <- readTVar (todos st)
      return (M.lookup sid m)
    case mt of
      Just t | ownerId t == userId u -> json t
      _ -> jsonError 404 "Todo not found"

  -- PUT /todos/:id
  put "/todos/:id" $ do
    u <- requireAuth st
    setHeader "Content-Type" "application/json"
    sid <- getIdFromRequest
    TodoUpdateReq mt md mc <- parseJsonBody
    case mt of
      Just t' | T.strip t' == "" -> jsonError 400 "Title is required"
      _ -> do
        now <- liftIO isoNow
        res <- liftIO . atomically $ do
          m <- readTVar (todos st)
          case M.lookup sid m of
            Just td | ownerId td == userId u -> do
              let td' = td { title = maybe (title td) id mt
                           , description = maybe (description td) id md
                           , completed = maybe (completed td) id mc
                           , updatedAt = now }
              modifyTVar' (todos st) (M.insert sid td')
              return (Right td')
            _ -> return (Left ())
        case res of
          Right td' -> json td'
          Left _ -> jsonError 404 "Todo not found"

  -- DELETE /todos/:id
  delete "/todos/:id" $ do
    u <- requireAuth st
    sid <- getIdFromRequest
    ok <- liftIO . atomically $ do
      m <- readTVar (todos st)
      case M.lookup sid m of
        Just td | ownerId td == userId u -> do
          modifyTVar' (todos st) (M.delete sid)
          return True
        _ -> return False
    if ok
      then do
        status status204
        raw ""
      else jsonError 404 "Todo not found"

main :: IO ()
main = do
  args <- getArgs
  port <- case args of
    ["--port", p] | Just n <- readMaybe p -> return n
    _ -> return (3000 :: Int)
  st <- newState
  let settings = setHost "0.0.0.0" $ setPort port defaultSettings
  app <- scottyApp (appRoutes st)
  runSettings settings app

-- Middleware to ensure JSON content-type on all responses except 204 (DELETE has no body)
setJsonContentType :: Middleware
setJsonContentType app req send = app req $ \res -> do
  let st = Wai.responseStatus res
  if st == status204
    then send res
    else do
      let hs = Wai.responseHeaders res
      let hs' = case lookup hContentType hs of
                  Just _  -> hs
                  Nothing -> (hContentType, "application/json") : hs
      send (Wai.mapResponseHeaders (const hs') res)
