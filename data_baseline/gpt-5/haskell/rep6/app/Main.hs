{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Web.Scotty                as S
import           Network.Wai               (Request, requestHeaders, pathInfo)
import           Network.Wai.Handler.Warp  (defaultSettings, runSettings, setHost, setPort)
import           Network.HTTP.Types.Status
import qualified Data.Text                 as T
import qualified Data.Text.Lazy            as TL
import qualified Data.ByteString.Char8     as BS
import           Data.IORef
import           Data.Time
import           Data.Maybe
import qualified Data.Map.Strict           as M
import           System.Environment        (getArgs)
import           Data.UUID.V4              (nextRandom)
import           Data.UUID                 (toText)
import           Web.Cookie                (parseCookies)
import           Data.Char                 (isAlphaNum)
import           Data.Aeson
import           Data.List                 (sortOn)
import           Text.Read                 (readMaybe)

-- Data types

data User = User { userId :: Int, username :: T.Text } deriving (Show, Eq)

instance ToJSON User where
  toJSON (User i u) = object ["id" .= i, "username" .= u]

-- Store user with password

data UserRecord = UserRecord { urUser :: User, urPassword :: T.Text }

-- Todo

data Todo = Todo
  { todoId      :: Int
  , title       :: T.Text
  , description :: T.Text
  , completed   :: Bool
  , createdAt   :: T.Text
  , updatedAt   :: T.Text
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON (Todo i t d c ca ua) = object
    [ "id" .= i
    , "title" .= t
    , "description" .= d
    , "completed" .= c
    , "created_at" .= ca
    , "updated_at" .= ua
    ]

-- Todo record stored with owner

data TodoRecord = TodoRecord { trTodo :: Todo, trOwnerId :: Int }

-- Global in-memory state

data AppState = AppState
  { usersById   :: IORef (M.Map Int UserRecord)
  , usersByName :: IORef (M.Map T.Text Int)
  , nextUserId  :: IORef Int
  , todosById   :: IORef (M.Map Int TodoRecord)
  , nextTodoId  :: IORef Int
  , sessions    :: IORef (M.Map T.Text Int) -- session token -> userId
  }

-- Helper: current time in ISO8601 UTC with seconds precision
isoNow :: IO T.Text
isoNow = do
  t <- getCurrentTime
  let secs = floor (utctDayTime t) :: Integer
      t' = UTCTime (utctDay t) (secondsToDiffTime (fromIntegral secs))
  pure . T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t'

-- Parsing helpers
jsonBody :: FromJSON a => ActionM (Either String a)
jsonBody = do
  b <- S.body
  pure $ eitherDecode b

-- Request bodies

data RegisterReq = RegisterReq { rrUsername :: T.Text, rrPassword :: T.Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq
    <$> o .: "username"
    <*> o .: "password"

data LoginReq = LoginReq { lrUsername :: T.Text, lrPassword :: T.Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq
    <$> o .: "username"
    <*> o .: "password"

data PasswordReq = PasswordReq { prOld :: T.Text, prNew :: T.Text }
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \o -> PasswordReq
    <$> o .: "old_password"
    <*> o .: "new_password"

data CreateTodoReq = CreateTodoReq { ctrTitle :: T.Text, ctrDesc :: Maybe T.Text }
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \o -> CreateTodoReq
    <$> o .: "title"
    <*> o .:? "description"

data UpdateTodoReq = UpdateTodoReq { utrTitle :: Maybe T.Text, utrDesc :: Maybe T.Text, utrCompleted :: Maybe Bool }
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> UpdateTodoReq
    <$> o .:? "title"
    <*> o .:? "description"
    <*> o .:? "completed"

-- Validation helpers
validUsername :: T.Text -> Bool
validUsername u = let l = T.length u in l >= 3 && l <= 50 && T.all (\c -> isAlphaNum c || c == '_') u

validPassword :: T.Text -> Bool
validPassword p = T.length p >= 8

-- Cookie helpers
getSessionToken :: Request -> Maybe T.Text
getSessionToken req = do
  ck <- lookup "Cookie" (requestHeaders req)
  let cookies = parseCookies ck
  t <- lookup "session_id" cookies
  pure (T.pack (BS.unpack t))

setSessionCookieHeader :: T.Text -> S.ActionM ()
setSessionCookieHeader token = do
  let cookieVal = TL.fromStrict $ T.concat ["session_id=", token, "; Path=/; HttpOnly"]
  S.addHeader "Set-Cookie" cookieVal

-- JSON helpers (force exact Content-Type)
jsonCT :: ToJSON a => a -> ActionM ()
jsonCT v = do
  S.setHeader "Content-Type" "application/json"
  S.json v

jsonError :: Status -> T.Text -> ActionM ()
jsonError st msg = do
  S.status st
  jsonCT (object ["error" .= msg])

jsonOK :: ToJSON a => a -> ActionM ()
jsonOK v = do
  S.status status200
  jsonCT v

jsonCreated :: ToJSON a => a -> ActionM ()
jsonCreated v = do
  S.status status201
  jsonCT v

jsonEmptyOK :: ActionM ()
jsonEmptyOK = do
  S.status status200
  jsonCT (object [])

-- Auth helper: require session
requireAuth :: AppState -> ActionM (Maybe UserRecord)
requireAuth st = do
  req <- S.request
  sessMap <- liftIO $ readIORef (sessions st)
  case getSessionToken req >>= (\t -> M.lookup t sessMap >>= \uid -> Just (t, uid)) of
    Nothing -> do
      jsonError status401 "Authentication required"
      pure Nothing
    Just (_tok, uid) -> do
      uMap <- liftIO $ readIORef (usersById st)
      case M.lookup uid uMap of
        Nothing -> do
          jsonError status401 "Authentication required"
          pure Nothing
        Just ur -> pure (Just ur)

-- Helper to get :id from path info
getTodoIdParam :: ActionM (Maybe Int)
getTodoIdParam = do
  req <- S.request
  let segs = pathInfo req
  case segs of
    ["todos", tidTxt] -> pure (readMaybe (T.unpack tidTxt))
    _                  -> pure Nothing

-- Main
main :: IO ()
main = do
  args <- getArgs
  port <- case args of
    ["--port", pStr] -> pure (read pStr :: Int)
    _ -> pure 3000

  usersIdRef <- newIORef M.empty
  usersNameRef <- newIORef M.empty
  nextUidRef <- newIORef 1
  todosRef <- newIORef M.empty
  nextTidRef <- newIORef 1
  sessionsRef <- newIORef M.empty
  let st = AppState usersIdRef usersNameRef nextUidRef todosRef nextTidRef sessionsRef

  app <- scottyApp $ do
    -- POST /register
    post "/register" $ do
      e <- jsonBody :: ActionM (Either String RegisterReq)
      case e of
        Left _ -> jsonError status400 "Invalid request body"
        Right (RegisterReq u p) -> do
          if not (validUsername u) then jsonError status400 "Invalid username" else
            if not (validPassword p) then jsonError status400 "Password too short" else do
              taken <- liftIO $ do
                m <- readIORef (usersByName st)
                pure (M.member u m)
              if taken then jsonError status409 "Username already exists" else do
                uid <- liftIO $ do
                  uid <- readIORef (nextUserId st)
                  writeIORef (nextUserId st) (uid + 1)
                  let user = User uid u
                  modifyIORef' (usersById st) (M.insert uid (UserRecord user p))
                  modifyIORef' (usersByName st) (M.insert u uid)
                  pure uid
                let user = User uid u
                jsonCreated user

    -- POST /login
    post "/login" $ do
      e <- jsonBody :: ActionM (Either String LoginReq)
      case e of
        Left _ -> jsonError status400 "Invalid request body"
        Right (LoginReq u p) -> do
          mUid <- liftIO $ do
            m <- readIORef (usersByName st)
            pure (M.lookup u m)
          case mUid of
            Nothing -> jsonError status401 "Invalid credentials"
            Just uid -> do
              ur <- liftIO $ do
                usersM <- readIORef (usersById st)
                pure (M.lookup uid usersM)
              case ur of
                Nothing -> jsonError status401 "Invalid credentials"
                Just (UserRecord user pw) -> if pw /= p then jsonError status401 "Invalid credentials" else do
                  token <- liftIO $ toText <$> nextRandom
                  liftIO $ modifyIORef' (sessions st) (M.insert token uid)
                  setSessionCookieHeader token
                  jsonOK user

    -- POST /logout
    post "/logout" $ do
      req <- S.request
      let mtok = getSessionToken req
      case mtok of
        Nothing -> jsonError status401 "Authentication required"
        Just tok -> do
          ok <- liftIO $ do
            sess <- readIORef (sessions st)
            let present = M.member tok sess
            if present then modifyIORef' (sessions st) (M.delete tok) else pure ()
            pure present
          if not ok then jsonError status401 "Authentication required" else jsonEmptyOK

    -- GET /me
    get "/me" $ do
      mu <- requireAuth st
      case mu of
        Nothing -> pure ()
        Just (UserRecord user _) -> jsonOK user

    -- PUT /password
    put "/password" $ do
      mu <- requireAuth st
      case mu of
        Nothing -> pure ()
        Just (UserRecord user curPw) -> do
          e <- jsonBody :: ActionM (Either String PasswordReq)
          case e of
            Left _ -> jsonError status400 "Invalid request body"
            Right (PasswordReq old newp) -> do
              if old /= curPw then jsonError status401 "Invalid credentials" else
                if not (validPassword newp) then jsonError status400 "Password too short" else do
                  liftIO $ modifyIORef' (usersById st) (M.adjust (\(UserRecord u' _) -> UserRecord u' newp) (userId user))
                  jsonEmptyOK

    -- GET /todos
    get "/todos" $ do
      mu <- requireAuth st
      case mu of
        Nothing -> pure ()
        Just (UserRecord user _) -> do
          allTodos <- liftIO $ readIORef (todosById st)
          let ts = map trTodo . filter ((== userId user) . trOwnerId) $ M.elems allTodos
              ts' = sortOn todoId ts
          jsonOK ts'

    -- POST /todos
    post "/todos" $ do
      mu <- requireAuth st
      case mu of
        Nothing -> pure ()
        Just (UserRecord user _) -> do
          e <- jsonBody :: ActionM (Either String CreateTodoReq)
          case e of
            Left _ -> jsonError status400 "Invalid request body"
            Right (CreateTodoReq t md) -> do
              if T.strip t == "" then jsonError status400 "Title is required" else do
                now <- liftIO isoNow
                tid <- liftIO $ do
                  i <- readIORef (nextTodoId st)
                  writeIORef (nextTodoId st) (i + 1)
                  pure i
                let todo = Todo tid t (fromMaybe "" md) False now now
                liftIO $ modifyIORef' (todosById st) (M.insert tid (TodoRecord todo (userId user)))
                jsonCreated todo

    -- GET /todos/:id
    get "/todos/:id" $ do
      mu <- requireAuth st
      case mu of
        Nothing -> pure ()
        Just (UserRecord user _) -> do
          mtid <- getTodoIdParam
          case mtid of
            Nothing -> jsonError status404 "Todo not found"
            Just tid -> do
              rec <- liftIO $ do
                m <- readIORef (todosById st)
                pure (M.lookup tid m)
              case rec of
                Nothing -> jsonError status404 "Todo not found"
                Just (TodoRecord todo owner) -> if owner /= userId user then jsonError status404 "Todo not found" else jsonOK todo

    -- PUT /todos/:id
    put "/todos/:id" $ do
      mu <- requireAuth st
      case mu of
        Nothing -> pure ()
        Just (UserRecord user _) -> do
          mtid <- getTodoIdParam
          case mtid of
            Nothing -> jsonError status404 "Todo not found"
            Just tid -> do
              e <- jsonBody :: ActionM (Either String UpdateTodoReq)
              case e of
                Left _ -> jsonError status400 "Invalid request body"
                Right (UpdateTodoReq mt md mc) -> do
                  mrec <- liftIO $ do
                    m <- readIORef (todosById st)
                    pure (M.lookup tid m)
                  case mrec of
                    Nothing -> jsonError status404 "Todo not found"
                    Just (TodoRecord todo owner) -> if owner /= userId user then jsonError status404 "Todo not found" else do
                      case mt of
                        Just t' | T.strip t' == "" -> jsonError status400 "Title is required"
                        _ -> do
                          now <- liftIO isoNow
                          let todo' = todo { title = fromMaybe (title todo) mt
                                           , description = fromMaybe (description todo) md
                                           , completed = fromMaybe (completed todo) mc
                                           , updatedAt = now
                                           }
                          liftIO $ modifyIORef' (todosById st) (M.insert tid (TodoRecord todo' owner))
                          jsonOK todo'

    -- DELETE /todos/:id
    delete "/todos/:id" $ do
      mu <- requireAuth st
      case mu of
        Nothing -> pure ()
        Just (UserRecord user _) -> do
          mtid <- getTodoIdParam
          case mtid of
            Nothing -> jsonError status404 "Todo not found"
            Just tid -> do
              mrec <- liftIO $ do
                m <- readIORef (todosById st)
                pure (M.lookup tid m)
              case mrec of
                Nothing -> jsonError status404 "Todo not found"
                Just (TodoRecord _ owner) -> if owner /= userId user then jsonError status404 "Todo not found" else do
                  liftIO $ modifyIORef' (todosById st) (M.delete tid)
                  S.status status204
                  S.raw ""

  runSettings ( setHost "0.0.0.0" $ setPort port defaultSettings ) app
