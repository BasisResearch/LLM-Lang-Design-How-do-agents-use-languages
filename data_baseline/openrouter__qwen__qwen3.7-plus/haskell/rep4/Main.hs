{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import Control.Concurrent.STM
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime, UTCTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import GHC.Generics (Generic)
import Network.Wai.Handler.Warp (runSettings, setPort, setHost, defaultSettings)
import Servant
import System.Environment (getArgs)
import Data.UUID.V4 (nextRandom)
import Data.UUID (toText)

-- | Data Types
data User = User
  { user_id :: Int
  , user_username :: Text
  , user_password :: Text
  } deriving (Show, Eq, Generic)

data Todo = Todo
  { todo_id :: Int
  , todo_owner_id :: Int
  , todo_title :: Text
  , todo_description :: Text
  , todo_completed :: Bool
  , todo_created_at :: UTCTime
  , todo_updated_at :: UTCTime
  } deriving (Show, Eq, Generic)

data AppStateData = AppStateData
  { app_users :: Map Int User
  , app_todos :: Map Int Todo
  , app_sessions :: Map Text Int
  , app_next_user_id :: Int
  , app_next_todo_id :: Int
  } deriving (Show, Generic)

type AppState = TVar AppStateData

initialState :: AppStateData
initialState = AppStateData
  { app_users = Map.empty
  , app_todos = Map.empty
  , app_sessions = Map.empty
  , app_next_user_id = 1
  , app_next_todo_id = 1
  }

-- | API Definition
type API =
       "register" :> ReqBody '[JSON] RegisterReq :> PostCreated '[JSON] UserResponse
  :<|> "login" :> ReqBody '[JSON] LoginReq :> Post '[JSON] (Headers '[Header "Set-Cookie" String] UserResponse)
  :<|> "logout" :> Header "Cookie" String :> Post '[JSON] EmptyResponse
  :<|> "me" :> Header "Cookie" String :> Get '[JSON] UserResponse
  :<|> "password" :> Header "Cookie" String :> ReqBody '[JSON] PasswordReq :> Put '[JSON] EmptyResponse
  :<|> "todos" :> Header "Cookie" String :> Get '[JSON] [TodoResponse]
  :<|> "todos" :> Header "Cookie" String :> ReqBody '[JSON] CreateTodoReq :> PostCreated '[JSON] TodoResponse
  :<|> "todos" :> Header "Cookie" String :> Capture "id" Int :> Get '[JSON] TodoResponse
  :<|> "todos" :> Header "Cookie" String :> Capture "id" Int :> ReqBody '[JSON] UpdateTodoReq :> Put '[JSON] TodoResponse
  :<|> "todos" :> Header "Cookie" String :> Capture "id" Int :> DeleteNoContent

-- | Request/Response Types
data RegisterReq = RegisterReq
  { reg_username :: Text
  , reg_password :: Text
  } deriving (Show, Eq, Generic)

instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \v -> RegisterReq
    <$> v .: "username"
    <*> v .: "password"

data LoginReq = LoginReq
  { log_username :: Text
  , log_password :: Text
  } deriving (Show, Eq, Generic)

instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \v -> LoginReq
    <$> v .: "username"
    <*> v .: "password"

data PasswordReq = PasswordReq
  { pwd_old_password :: Text
  , pwd_new_password :: Text
  } deriving (Show, Eq, Generic)

instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \v -> PasswordReq
    <$> v .: "old_password"
    <*> v .: "new_password"

data CreateTodoReq = CreateTodoReq
  { ctd_title :: Text
  , ctd_description :: Maybe Text
  } deriving (Show, Eq, Generic)

instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \v -> CreateTodoReq
    <$> v .: "title"
    <*> v .:? "description"

data UpdateTodoReq = UpdateTodoReq
  { utd_title :: Maybe Text
  , utd_description :: Maybe Text
  , utd_completed :: Maybe Bool
  } deriving (Show, Eq, Generic)

instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \v -> UpdateTodoReq
    <$> v .:? "title"
    <*> v .:? "description"
    <*> v .:? "completed"

data UserResponse = UserResponse
  { resp_id :: Int
  , resp_username :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON UserResponse where
  toJSON (UserResponse i u) = object ["id" .= i, "username" .= u]

data TodoResponse = TodoResponse
  { tres_id :: Int
  , tres_title :: Text
  , tres_description :: Text
  , tres_completed :: Bool
  , tres_created_at :: Text
  , tres_updated_at :: Text
  } deriving (Show, Eq, Generic)

formatTimeISO :: UTCTime -> Text
formatTimeISO t = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t)

instance ToJSON TodoResponse where
  toJSON (TodoResponse i ti d c ca ua) = object
    [ "id" .= i
    , "title" .= ti
    , "description" .= d
    , "completed" .= c
    , "created_at" .= ca
    , "updated_at" .= ua
    ]

data EmptyResponse = EmptyResponse
instance ToJSON EmptyResponse where
  toJSON _ = object []

-- | Error Helpers
err401Json :: Text -> ServerError
err401Json msg = err401 { errBody = encode (object ["error" .= msg]), errHeaders = [("Content-Type", "application/json")] }

err400Json :: Text -> ServerError
err400Json msg = err400 { errBody = encode (object ["error" .= msg]), errHeaders = [("Content-Type", "application/json")] }

err404Json :: Text -> ServerError
err404Json msg = err404 { errBody = encode (object ["error" .= msg]), errHeaders = [("Content-Type", "application/json")] }

err409Json :: Text -> ServerError
err409Json msg = err409 { errBody = encode (object ["error" .= msg]), errHeaders = [("Content-Type", "application/json")] }

-- | Validation
isValidUsername :: Text -> Bool
isValidUsername u =
  let len = T.length u
  in len >= 3 && len <= 50 && T.all isAllowedChar u
  where
    isAllowedChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'

isValidPassword :: Text -> Bool
isValidPassword p = T.length p >= 8

validateTitle :: Maybe Text -> Either Text Text
validateTitle Nothing = Left "Title is required"
validateTitle (Just t) | T.null t = Left "Title is required"
validateTitle (Just t) = Right t

-- | Auth Helper
checkAuth :: AppState -> Maybe String -> Handler Int
checkAuth state mCookie = do
  case mCookie of
    Nothing -> throwError $ err401Json "Authentication required"
    Just cookieStr -> do
      let cookiePairs = map (break (== '=')) (splitOn ';' cookieStr)
          parsed = map (\(k, v) -> (T.strip (T.pack k), T.strip (T.pack (dropWhile (== '=') v)))) cookiePairs
      case lookup "session_id" parsed of
        Just sessionId -> do
          stateData <- liftIO $ readTVarIO state
          case Map.lookup sessionId (app_sessions stateData) of
            Just uid -> return uid
            Nothing -> throwError $ err401Json "Authentication required"
        Nothing -> throwError $ err401Json "Authentication required"
  where
    splitOn :: Char -> String -> [String]
    splitOn delim s =
      let (before, after) = break (== delim) s
       in if null after then [before] else before : splitOn delim (drop 1 after)

-- | Handlers
register :: AppState -> RegisterReq -> Handler UserResponse
register state req = do
  let uname = reg_username req
      pwd = reg_password req
  unless (isValidUsername uname) $
    throwError $ err400Json "Invalid username"
  unless (isValidPassword pwd) $
    throwError $ err400Json "Password too short"
  
  currentState <- liftIO $ readTVarIO state
  let existingUser = find (\u -> user_username u == uname) (Map.elems (app_users currentState))
  case existingUser of
    Just _ -> throwError $ err409Json "Username already exists"
    Nothing -> do
      let newId = app_next_user_id currentState
          newUser = User { user_id = newId, user_username = uname, user_password = pwd }
          newState = currentState 
            { app_users = Map.insert newId newUser (app_users currentState)
            , app_next_user_id = newId + 1
            }
      liftIO $ atomically $ writeTVar state newState
      return $ UserResponse newId uname

login :: AppState -> LoginReq -> Handler (Headers '[Header "Set-Cookie" String] UserResponse)
login state req = do
  let uname = log_username req
      pwd = log_password req
  
  currentState <- liftIO $ readTVarIO state
  let matchingUser = find (\u -> user_username u == uname && user_password u == pwd) (Map.elems (app_users currentState))
  case matchingUser of
    Nothing -> throwError $ err401Json "Invalid credentials"
    Just u -> do
      uuid <- liftIO $ nextRandom
      let sessionId = toText uuid
          newState = currentState
            { app_sessions = Map.insert sessionId (user_id u) (app_sessions currentState) }
      liftIO $ atomically $ writeTVar state newState
      
      let setCookieHeader = "session_id=" ++ T.unpack sessionId ++ "; Path=/; HttpOnly"
      
      return $ addHeader setCookieHeader (UserResponse (user_id u) (user_username u))

logout :: AppState -> Maybe String -> Handler EmptyResponse
logout state mCookie = do
  let cookieStr = fromJust mCookie
  _uid <- checkAuth state mCookie
  let cookiePairs = map (break (== '=')) (splitOn ';' cookieStr)
      parsed = map (\(k, v) -> (T.strip (T.pack k), T.strip (T.pack (dropWhile (== '=') v)))) cookiePairs
      sessionId = fromJust (lookup "session_id" parsed)
  currentState <- liftIO $ readTVarIO state
  let newState = currentState
        { app_sessions = Map.delete sessionId (app_sessions currentState) }
  liftIO $ atomically $ writeTVar state newState
  return EmptyResponse
  where
    splitOn :: Char -> String -> [String]
    splitOn delim s =
      let (before, after) = break (== delim) s
       in if null after then [before] else before : splitOn delim (drop 1 after)

me :: AppState -> Maybe String -> Handler UserResponse
me state mCookie = do
  uid <- checkAuth state mCookie
  currentState <- liftIO $ readTVarIO state
  case Map.lookup uid (app_users currentState) of
    Nothing -> throwError $ err401Json "Authentication required"
    Just u -> return $ UserResponse (user_id u) (user_username u)

password :: AppState -> Maybe String -> PasswordReq -> Handler EmptyResponse
password state mCookie req = do
  uid <- checkAuth state mCookie
  let oldPwd = pwd_old_password req
      newPwd = pwd_new_password req
  unless (isValidPassword newPwd) $
    throwError $ err400Json "Password too short"
  
  currentState <- liftIO $ readTVarIO state
  case Map.lookup uid (app_users currentState) of
    Nothing -> throwError $ err401Json "Authentication required"
    Just u -> do
      unless (user_password u == oldPwd) $
        throwError $ err401Json "Invalid credentials"
      
      let newU = u { user_password = newPwd }
          newState = currentState { app_users = Map.insert uid newU (app_users currentState) }
      liftIO $ atomically $ writeTVar state newState
      return EmptyResponse

getTodos :: AppState -> Maybe String -> Handler [TodoResponse]
getTodos state mCookie = do
  uid <- checkAuth state mCookie
  currentState <- liftIO $ readTVarIO state
  let userTodos = Map.elems (Map.filter (\t -> todo_owner_id t == uid) (app_todos currentState))
      sortedTodos = sortOn todo_id userTodos
  return $ map todoToResponse sortedTodos

createTodo :: AppState -> Maybe String -> CreateTodoReq -> Handler TodoResponse
createTodo state mCookie req = do
  uid <- checkAuth state mCookie
  title <- case validateTitle (Just (ctd_title req)) of
    Left err -> throwError $ err400Json err
    Right t -> return t
  
  let desc = fromMaybe "" (ctd_description req)
  
  currentState <- liftIO $ readTVarIO state
  now <- liftIO getCurrentTime
  let newId = app_next_todo_id currentState
      newTodo = Todo
        { todo_id = newId
        , todo_owner_id = uid
        , todo_title = title
        , todo_description = desc
        , todo_completed = False
        , todo_created_at = now
        , todo_updated_at = now
        }
      newState = currentState
        { app_todos = Map.insert newId newTodo (app_todos currentState)
        , app_next_todo_id = newId + 1
        }
  liftIO $ atomically $ writeTVar state newState
  return $ todoToResponse newTodo

getTodo :: AppState -> Maybe String -> Int -> Handler TodoResponse
getTodo state mCookie tid = do
  uid <- checkAuth state mCookie
  currentState <- liftIO $ readTVarIO state
  case Map.lookup tid (app_todos currentState) of
    Just t | todo_owner_id t == uid -> return $ todoToResponse t
    _ -> throwError $ err404Json "Todo not found"

updateTodo :: AppState -> Maybe String -> Int -> UpdateTodoReq -> Handler TodoResponse
updateTodo state mCookie tid req = do
  uid <- checkAuth state mCookie
  currentState <- liftIO $ readTVarIO state
  case Map.lookup tid (app_todos currentState) of
    Just t | todo_owner_id t == uid -> do
      newTitle <- case utd_title req of
        Nothing -> return (todo_title t)
        Just t' -> case validateTitle (Just t') of
          Left err -> throwError $ err400Json err
          Right t'' -> return t''
      
      let newDesc = fromMaybe (todo_description t) (utd_description req)
          newCompleted = fromMaybe (todo_completed t) (utd_completed req)
      
      now <- liftIO getCurrentTime
      let updatedTodo = t
            { todo_title = newTitle
            , todo_description = newDesc
            , todo_completed = newCompleted
            , todo_updated_at = now
            }
          newState = currentState
            { app_todos = Map.insert tid updatedTodo (app_todos currentState) }
      liftIO $ atomically $ writeTVar state newState
      return $ todoToResponse updatedTodo
    _ -> throwError $ err404Json "Todo not found"

deleteTodo :: AppState -> Maybe String -> Int -> Handler NoContent
deleteTodo state mCookie tid = do
  uid <- checkAuth state mCookie
  currentState <- liftIO $ readTVarIO state
  case Map.lookup tid (app_todos currentState) of
    Just t | todo_owner_id t == uid -> do
      let newState = currentState
            { app_todos = Map.delete tid (app_todos currentState) }
      liftIO $ atomically $ writeTVar state newState
      return NoContent
    _ -> throwError $ err404Json "Todo not found"

-- | Server setup
todoServer :: AppState -> Server API
todoServer state =
       register state
  :<|> login state
  :<|> logout state
  :<|> me state
  :<|> password state
  :<|> getTodos state
  :<|> createTodo state
  :<|> getTodo state
  :<|> updateTodo state
  :<|> deleteTodo state

todoToResponse :: Todo -> TodoResponse
todoToResponse t = TodoResponse
  { tres_id = todo_id t
  , tres_title = todo_title t
  , tres_description = todo_description t
  , tres_completed = todo_completed t
  , tres_created_at = formatTimeISO (todo_created_at t)
  , tres_updated_at = formatTimeISO (todo_updated_at t)
  }

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
        ["--port", p] -> read p
        _ -> 8080
  
  state <- newTVarIO initialState
  let app = serve (Proxy :: Proxy API) (todoServer state)
  putStrLn $ "Starting server on port " ++ show port
  runSettings (setPort port $ setHost "0.0.0.0" defaultSettings) app