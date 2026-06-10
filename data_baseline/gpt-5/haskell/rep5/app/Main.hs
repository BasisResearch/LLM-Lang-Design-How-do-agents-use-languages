{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Web.Scotty
import           Network.HTTP.Types.Status (status201, status204, status400, status401, status404, status409)
import           Network.Wai.Handler.Warp (defaultSettings, setPort, setHost)
import           Network.Wai (Request, pathInfo)
import           Data.String (fromString)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Map.Strict as M
import           Data.IORef
import           Data.Time (getCurrentTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           Control.Monad.IO.Class (liftIO)
import           System.Environment (getArgs)
import           Text.Read (readMaybe)
import           Data.Aeson
import           Data.Aeson (Value)
import           Data.Maybe (fromMaybe)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4

-- Data types

data User = User { uId :: Int, uName :: T.Text, uPass :: T.Text } deriving (Show, Eq)

instance ToJSON User where
  toJSON (User i n _) = object ["id" .= i, "username" .= n]

data Todo = Todo
  { tId :: Int
  , tUserId :: Int
  , tTitle :: T.Text
  , tDescription :: T.Text
  , tCompleted :: Bool
  , tCreatedAt :: T.Text
  , tUpdatedAt :: T.Text
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON (Todo i _ title desc comp cAt uAt) = object
    [ "id" .= i
    , "title" .= title
    , "description" .= desc
    , "completed" .= comp
    , "created_at" .= cAt
    , "updated_at" .= uAt
    ]

-- Storage

data AppState = AppState
  { users :: M.Map Int User
  , usernames :: M.Map T.Text Int -- username -> userId
  , nextUserId :: Int
  , sessions :: M.Map T.Text Int -- token -> userId
  , todos :: M.Map Int Todo
  , userTodos :: M.Map Int [Int] -- userId -> [todoIds] asc
  , nextTodoId :: Int
  }

defaultState :: AppState
defaultState = AppState M.empty M.empty 1 M.empty M.empty M.empty 1

-- Helpers
setJson :: ActionM ()
setJson = setHeader "Content-Type" "application/json"

-- Generate ISO8601 UTC timestamp with second precision
nowIso :: IO T.Text
nowIso = do
  t <- getCurrentTime
  let fmt = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t
  return (T.pack fmt)

-- username validation
validUsername :: T.Text -> Bool
validUsername n =
  let l = T.length n
      okChar c = (c>='a'&&c<='z') || (c>='A'&&c<='Z') || (c>='0'&&c<='9') || c=='_'
  in l >= 3 && l <= 50 && T.all okChar n

-- Parse simple cookies
parseCookies :: TL.Text -> M.Map T.Text T.Text
parseCookies raw =
  let parts = map (T.strip . TL.toStrict) $ TL.splitOn ";" raw
      kvs = map (T.breakOn "=") parts
      toPair (k,v) = if T.null v then Nothing else Just (k, T.drop 1 v)
  in M.fromList $ foldr (\x acc -> maybe acc (:acc) (toPair x)) [] kvs

getSessionUser :: IORef AppState -> ActionM (Maybe (T.Text, User))
getSessionUser ref = do
  mc <- header "Cookie"
  case mc of
    Nothing -> return Nothing
    Just hraw -> do
      let ck = parseCookies hraw
      case M.lookup "session_id" ck of
        Nothing -> return Nothing
        Just tok -> do
          st <- liftIO $ readIORef ref
          case M.lookup tok (sessions st) of
            Nothing -> return Nothing
            Just uid -> case M.lookup uid (users st) of
                          Nothing -> return Nothing
                          Just u  -> return (Just (tok, u))

requireAuth :: IORef AppState -> ActionM (T.Text, User)
requireAuth ref = do
  mu <- getSessionUser ref
  case mu of
    Nothing -> do
      status status401
      setJson
      json $ object ["error" .= ("Authentication required" :: T.Text)]
      finish
    Just tu -> return tu

-- Read JSON body helper with error on parse failure
parseJsonBody :: FromJSON a => ActionM (Either T.Text a)
parseJsonBody = do
  b <- body
  case eitherDecode b of
    Left _ -> return $ Left "Invalid JSON"
    Right v -> return $ Right v

-- Request payloads

data RegisterReq = RegisterReq { rUsername :: T.Text, rPassword :: T.Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq <$> o .: "username" <*> o .: "password"

data LoginReq = LoginReq { luser :: T.Text, lpass :: T.Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq <$> o .: "username" <*> o .: "password"

data PasswordReq = PasswordReq { oldPassword :: T.Text, newPassword :: T.Text }
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \o -> PasswordReq <$> o .: "old_password" <*> o .: "new_password"

data CreateTodoReq = CreateTodoReq { cTitle :: T.Text, cDesc :: Maybe T.Text }
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \o -> CreateTodoReq <$> o .: "title" <*> o .:? "description"

data UpdateTodoReq = UpdateTodoReq { uTitle :: Maybe T.Text, uDesc :: Maybe T.Text, uComp :: Maybe Bool }
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> UpdateTodoReq <$> o .:? "title" <*> o .:? "description" <*> o .:? "completed"

-- Utilities
newSessionToken :: IO T.Text
newSessionToken = T.pack . UUID.toString <$> UUIDv4.nextRandom

-- Modify state with atomic IORef
modifyState :: IORef AppState -> (AppState -> (AppState, a)) -> IO a
modifyState ref f = atomicModifyIORef' ref (\s -> let (s', a) = f s in (s', a))

-- Extract :id from pathInfo for /todos/:id
getTodoIdFromPath :: ActionM (Maybe Int)
getTodoIdFromPath = do
  req <- request
  let segs = pathInfo req
  return $ case segs of
    ("todos":sid:_) -> readMaybe (T.unpack sid)
    _ -> Nothing

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
               ("--port":p:_) -> maybe 3000 id (readMaybe p)
               _               -> 3000 :: Int
      opts = Options { verbose = 0
                     , settings = setHost (fromString "0.0.0.0") $ setPort port defaultSettings
                     }
  stRef <- newIORef defaultState

  scottyOpts opts $ do
    -- POST /register
    post "/register" $ do
      setJson
      eb <- parseJsonBody :: ActionM (Either T.Text RegisterReq)
      case eb of
        Left _ -> do status status400; json $ object ["error" .= ("Invalid JSON" :: T.Text)]
        Right (RegisterReq uname pwd) -> do
          if not (validUsername uname)
            then do status status400; json $ object ["error" .= ("Invalid username" :: T.Text)]
            else if T.length pwd < 8
              then do status status400; json $ object ["error" .= ("Password too short" :: T.Text)]
              else do
                res <- liftIO $ modifyState stRef $ \s ->
                  if M.member uname (usernames s)
                    then (s, Left ("Username already exists" :: T.Text))
                    else let uid = nextUserId s
                             u = User uid uname pwd
                             s' = s { users = M.insert uid u (users s)
                                    , usernames = M.insert uname uid (usernames s)
                                    , nextUserId = uid + 1 }
                          in (s', Right u)
                case res of
                  Left _ -> do status status409; json $ object ["error" .= ("Username already exists" :: T.Text)]
                  Right u -> do status status201; json u

    -- POST /login
    post "/login" $ do
      setJson
      eb <- parseJsonBody :: ActionM (Either T.Text LoginReq)
      case eb of
        Left _ -> do status status400; json $ object ["error" .= ("Invalid JSON" :: T.Text)]
        Right (LoginReq uname pwd) -> do
          st <- liftIO $ readIORef stRef
          case M.lookup uname (usernames st) >>= (\uid -> M.lookup uid (users st)) of
            Nothing -> do status status401; json $ object ["error" .= ("Invalid credentials" :: T.Text)]
            Just u -> if uPass u /= pwd
                        then do status status401; json $ object ["error" .= ("Invalid credentials" :: T.Text)]
                        else do
                          tok <- liftIO newSessionToken
                          liftIO $ modifyIORef' stRef $ \s -> s { sessions = M.insert tok (uId u) (sessions s) }
                          setHeader "Set-Cookie" (TL.fromStrict $ T.concat ["session_id=", tok, "; Path=/; HttpOnly"]) 
                          json u

    -- POST /logout
    post "/logout" $ do
      setJson
      mtokUser <- getSessionUser stRef
      case mtokUser of
        Nothing -> do status status401; json $ object ["error" .= ("Authentication required" :: T.Text)]
        Just (tok, _) -> do
          liftIO $ modifyIORef' stRef $ \s -> s { sessions = M.delete tok (sessions s) }
          json (object [] :: Value)

    -- GET /me
    get "/me" $ do
      setJson
      (_, u) <- requireAuth stRef
      json u

    -- PUT /password
    put "/password" $ do
      setJson
      (_, u) <- requireAuth stRef
      eb <- parseJsonBody :: ActionM (Either T.Text PasswordReq)
      case eb of
        Left _ -> do status status400; json $ object ["error" .= ("Invalid JSON" :: T.Text)]
        Right (PasswordReq oldp newp) -> do
          if uPass u /= oldp
            then do status status401; json $ object ["error" .= ("Invalid credentials" :: T.Text)]
            else if T.length newp < 8
              then do status status400; json $ object ["error" .= ("Password too short" :: T.Text)]
              else do
                liftIO $ modifyIORef' stRef $ \s ->
                  let u' = u { uPass = newp }
                  in s { users = M.insert (uId u) u' (users s) }
                json (object [] :: Value)

    -- GET /todos
    get "/todos" $ do
      setJson
      (_, u) <- requireAuth stRef
      st <- liftIO $ readIORef stRef
      let tids = M.findWithDefault [] (uId u) (userTodos st)
          ts = [ td | tid <- tids, Just td <- [M.lookup tid (todos st)] ]
      json ts

    -- POST /todos
    post "/todos" $ do
      setJson
      (_, u) <- requireAuth stRef
      eb <- parseJsonBody :: ActionM (Either T.Text CreateTodoReq)
      case eb of
        Left _ -> do status status400; json $ object ["error" .= ("Invalid JSON" :: T.Text)]
        Right (CreateTodoReq title mdesc) -> do
          if T.strip title == ""
            then do status status400; json $ object ["error" .= ("Title is required" :: T.Text)]
            else do
              ts <- liftIO nowIso
              todo <- liftIO $ modifyState stRef $ \s ->
                let tid = nextTodoId s
                    td = Todo tid (uId u) title (fromMaybe "" mdesc) False ts ts
                    prev = M.findWithDefault [] (uId u) (userTodos s)
                    s' = s { todos = M.insert tid td (todos s)
                           , userTodos = M.insert (uId u) (prev ++ [tid]) (userTodos s)
                           , nextTodoId = tid + 1 }
                in (s', td)
              status status201
              json todo

    -- GET /todos/:id
    get "/todos/:id" $ do
      setJson
      (_, u) <- requireAuth stRef
      mtid <- getTodoIdFromPath
      case mtid of
        Nothing -> do status status404; json $ object ["error" .= ("Todo not found" :: T.Text)]
        Just tid -> do
          st <- liftIO $ readIORef stRef
          case M.lookup tid (todos st) of
            Just td | tUserId td == uId u -> json td
            _ -> do status status404; json $ object ["error" .= ("Todo not found" :: T.Text)]

    -- PUT /todos/:id
    put "/todos/:id" $ do
      setJson
      (_, u) <- requireAuth stRef
      mtid <- getTodoIdFromPath
      case mtid of
        Nothing -> do status status404; json $ object ["error" .= ("Todo not found" :: T.Text)]
        Just tid -> do
          eb <- parseJsonBody :: ActionM (Either T.Text UpdateTodoReq)
          case eb of
            Left _ -> do status status400; json $ object ["error" .= ("Invalid JSON" :: T.Text)]
            Right (UpdateTodoReq mtitle mdesc mcomp) -> do
              case mtitle of
                Just t | T.strip t == "" -> do status status400; json $ object ["error" .= ("Title is required" :: T.Text)]
                _ -> do
                  mtd <- liftIO $ modifyState stRef $ \s ->
                    case M.lookup tid (todos s) of
                      Just td | tUserId td == uId u -> (s, Just td)
                      _ -> (s, Nothing)
                  case mtd of
                    Nothing -> do status status404; json $ object ["error" .= ("Todo not found" :: T.Text)]
                    Just td -> do
                      ts <- liftIO nowIso
                      let td' = td { tTitle = maybe (tTitle td) id mtitle
                                    , tDescription = maybe (tDescription td) id mdesc
                                    , tCompleted = maybe (tCompleted td) id mcomp
                                    , tUpdatedAt = ts }
                      liftIO $ modifyIORef' stRef $ \s -> s { todos = M.insert tid td' (todos s) }
                      json td'

    -- DELETE /todos/:id
    delete "/todos/:id" $ do
      (_, u) <- requireAuth stRef
      mtid <- getTodoIdFromPath
      case mtid of
        Nothing -> do
          status status404
          setJson
          json $ object ["error" .= ("Todo not found" :: T.Text)]
        Just tid -> do
          res <- liftIO $ modifyState stRef $ \s ->
            case M.lookup tid (todos s) of
              Just td | tUserId td == uId u ->
                let s' = s { todos = M.delete tid (todos s)
                           , userTodos = M.adjust (filter (/= tid)) (uId u) (userTodos s) }
                in (s', True)
              _ -> (s, False)
          if res
            then do status status204; finish
            else do status status404; setJson; json $ object ["error" .= ("Todo not found" :: T.Text)]
