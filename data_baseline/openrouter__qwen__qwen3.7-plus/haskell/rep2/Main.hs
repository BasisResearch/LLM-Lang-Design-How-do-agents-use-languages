{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}

module Main where

import Control.Concurrent.STM
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.Time
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import qualified Web.Scotty as S
import Network.HTTP.Types (Status, status200, status201, status204, status400, status401, status404, status409)
import Network.Wai (pathInfo, requestHeaders)
import qualified Data.ByteString.Char8 as B
import System.Environment (getArgs)
import GHC.Generics
import Data.Maybe (fromMaybe)
import Data.List (sortOn)
import Text.Read (readMaybe)

-- | Application state
data AppState = AppState
  { stNextUserId :: TVar Int
  , stNextTodoId :: TVar Int
  , stUsers :: TVar (Map Int User)
  , stUserByName :: TVar (Map Text Int)
  , stTodos :: TVar (Map Int Todo)
  , stSessions :: TVar (Map Text Int)
  }

-- | Internal User representation
data User = User
  { userId :: Int
  , userUsername :: Text
  , userPassword :: Text
  } deriving (Show, Eq)

-- | Internal Todo representation
data Todo = Todo
  { todoId :: Int
  , todoUserId :: Int
  , todoTitle :: Text
  , todoDescription :: Text
  , todoCompleted :: Bool
  , todoCreatedAt :: UTCTime
  , todoUpdatedAt :: UTCTime
  } deriving (Show, Eq)

-- | API Response Types
data UserResponse = UserResponse
  { respId :: Int
  , username :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON UserResponse where
  toJSON u = object [ "id" .= respId u, "username" .= username u ]

data TodoResponse = TodoResponse
  { resId :: Int
  , resTitle :: Text
  , resDescription :: Text
  , resCompleted :: Bool
  , resCreatedAt :: Text
  , resUpdatedAt :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON TodoResponse where
  toJSON t = object
    [ "id" .= resId t
    , "title" .= resTitle t
    , "description" .= resDescription t
    , "completed" .= resCompleted t
    , "created_at" .= resCreatedAt t
    , "updated_at" .= resUpdatedAt t
    ]

-- | API Request Types
data RegisterRequest = RegisterRequest
  { regUsername :: Maybe Text
  , regPassword :: Maybe Text
  } deriving (Show, Eq)

instance FromJSON RegisterRequest where
  parseJSON = withObject "RegisterRequest" $ \v -> do
    mUser <- v .:? "username"
    mPass <- v .:? "password"
    pure RegisterRequest { regUsername = fromMaybe "" <$> mUser, regPassword = fromMaybe "" <$> mPass }

data LoginRequest = LoginRequest
  { logUsername :: Maybe Text
  , logPassword :: Maybe Text
  } deriving (Show, Eq)

instance FromJSON LoginRequest where
  parseJSON = withObject "LoginRequest" $ \v -> do
    mUser <- v .:? "username"
    mPass <- v .:? "password"
    pure LoginRequest { logUsername = fromMaybe "" <$> mUser, logPassword = fromMaybe "" <$> mPass }

data PasswordRequest = PasswordRequest
  { oldPassword :: Maybe Text
  , newPassword :: Maybe Text
  } deriving (Show, Eq)

instance FromJSON PasswordRequest where
  parseJSON = withObject "PasswordRequest" $ \v -> do
    mOld <- v .:? "old_password"
    mNew <- v .:? "new_password"
    pure PasswordRequest { oldPassword = fromMaybe "" <$> mOld, newPassword = fromMaybe "" <$> mNew }

data TodoRequest = TodoRequest
  { reqTitle :: Maybe Text
  , reqDescription :: Maybe Text
  } deriving (Show, Eq)

instance FromJSON TodoRequest where
  parseJSON = withObject "TodoRequest" $ \v -> do
    mTitle <- v .:? "title"
    mDesc <- v .:? "description"
    pure TodoRequest { reqTitle = mTitle, reqDescription = fromMaybe "" <$> mDesc }

data TodoUpdateRequest = TodoUpdateRequest
  { updTitle :: Maybe Text
  , updDescription :: Maybe Text
  , updCompleted :: Maybe Bool
  } deriving (Show, Eq)

instance FromJSON TodoUpdateRequest where
  parseJSON = withObject "TodoUpdateRequest" $ \v -> do
    mTitle <- v .:? "title"
    mDesc <- v .:? "description"
    mComp <- v .:? "completed"
    pure TodoUpdateRequest { updTitle = mTitle, updDescription = mDesc, updCompleted = mComp }

-- | Helpers
formatTimeStr :: UTCTime -> Text
formatTimeStr t = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t

toTodoResponse :: Todo -> TodoResponse
toTodoResponse todo = TodoResponse
  { resId = todoId todo
  , resTitle = todoTitle todo
  , resDescription = todoDescription todo
  , resCompleted = todoCompleted todo
  , resCreatedAt = formatTimeStr (todoCreatedAt todo)
  , resUpdatedAt = formatTimeStr (todoUpdatedAt todo)
  }

isValidUsername :: Text -> Bool
isValidUsername t = len >= 3 && len <= 50 && T.all isValidChar t
  where
    len = T.length t
    isValidChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'

jsonError :: Status -> Text -> S.ActionM ()
jsonError st msg = do
  S.status st
  S.json $ object ["error" .= msg]

getCookie :: Text -> S.ActionM (Maybe Text)
getCookie name = do
  req <- S.request
  let cookieHeader = lookup "cookie" (requestHeaders req)
  case cookieHeader of
    Nothing -> return Nothing
    Just hdr -> 
      let hdrText = T.pack $ B.unpack hdr
          parts = T.split (== ';') hdrText
          pairs = map (\p -> let (k, v) = T.break (== '=') (T.strip p) in (T.strip k, T.strip (T.drop 1 v))) parts
      in return $ lookup name pairs

getPathParam :: Int -> S.ActionM (Maybe Text)
getPathParam idx = do
  req <- S.request
  let parts = pathInfo req
  if idx < length parts
    then return $ Just $ parts !! idx
    else return Nothing

requireAuth :: AppState -> S.ActionM (Either Text Int)
requireAuth app = do
  mSession <- getCookie "session_id"
  case mSession of
    Nothing -> return (Left "Authentication required")
    Just sid -> do
      res <- liftIO $ atomically $ do
        sessions <- readTVar (stSessions app)
        case Map.lookup sid sessions of
          Just uid -> return (Right uid)
          Nothing -> return (Left "Authentication required")
      return res

-- | Handlers
handleRegister :: AppState -> S.ActionM ()
handleRegister app = do
  req <- S.jsonData :: S.ActionM RegisterRequest
  let uName = fromMaybe "" (regUsername req)
      pWord = fromMaybe "" (regPassword req)
  
  if not (isValidUsername uName)
    then jsonError status400 "Invalid username"
    else if T.length pWord < 8
      then jsonError status400 "Password too short"
      else do
        res <- liftIO $ atomically $ do
          usersByName <- readTVar $ stUserByName app
          if Map.member uName usersByName
            then return (Left "Username already exists")
            else do
              uid <- readTVar $ stNextUserId app
              writeTVar (stNextUserId app) (uid + 1)
              let newUser = User uid uName pWord
              modifyTVar (stUsers app) (Map.insert uid newUser)
              modifyTVar (stUserByName app) (Map.insert uName uid)
              return (Right uid)
        case res of
          Left err -> jsonError status409 err
          Right uid -> do
            S.status status201
            S.json $ UserResponse uid uName

handleLogin :: AppState -> S.ActionM ()
handleLogin app = do
  req <- S.jsonData :: S.ActionM LoginRequest
  let uName = fromMaybe "" (logUsername req)
      pWord = fromMaybe "" (logPassword req)
  
  res <- liftIO $ do
    sid <- T.pack . toString <$> nextRandom
    atomically $ do
      usersByName <- readTVar $ stUserByName app
      case Map.lookup uName usersByName of
        Nothing -> return (Left "Invalid credentials")
        Just uid -> do
          users <- readTVar $ stUsers app
          case Map.lookup uid users of
            Just u | userPassword u == pWord -> do
              modifyTVar (stSessions app) (Map.insert sid uid)
              return (Right (uid, sid))
            _otherwise -> return (Left "Invalid credentials")
  
  case res of
    Left err -> jsonError status401 err
    Right (uid, sid) -> do
      S.setHeader (LT.pack "Set-Cookie") (LT.pack $ "session_id=" ++ T.unpack sid ++ "; Path=/; HttpOnly")
      S.status status200
      S.json $ UserResponse uid uName

handleLogout :: AppState -> S.ActionM ()
handleLogout app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right _uid -> do
      mSession <- getCookie "session_id"
      liftIO $ atomically $ do
        case mSession of
          Just sid -> modifyTVar (stSessions app) (Map.delete sid)
          Nothing -> return ()
      S.status status200
      S.json $ object []

handleMe :: AppState -> S.ActionM ()
handleMe app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right uid -> do
      user <- liftIO $ atomically $ do
        users <- readTVar $ stUsers app
        case Map.lookup uid users of
          Just u -> return (Right u)
          Nothing -> return (Left "User not found")
      case user of
        Left _ -> jsonError status401 "Authentication required"
        Right u -> S.json $ UserResponse (userId u) (userUsername u)

handlePassword :: AppState -> S.ActionM ()
handlePassword app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right uid -> do
      req <- S.jsonData :: S.ActionM PasswordRequest
      let oldP = fromMaybe "" (oldPassword req)
          newP = fromMaybe "" (newPassword req)
      
      res <- liftIO $ atomically $ do
        users <- readTVar $ stUsers app
        case Map.lookup uid users of
          Just u | userPassword u == oldP ->
            if T.length newP < 8
            then return (Left "Password too short")
            else do
              let updatedUser = u { userPassword = newP }
              modifyTVar (stUsers app) (Map.insert uid updatedUser)
              return (Right ())
          _otherwise -> return (Left "Invalid credentials")
      
      case res of
        Left err -> 
          if err == "Password too short" 
            then jsonError status400 err 
            else jsonError status401 err
        Right () -> do
          S.status status200
          S.json $ object []

handleGetTodos :: AppState -> S.ActionM ()
handleGetTodos app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right uid -> do
      todosList <- liftIO $ atomically $ do
        todos <- readTVar $ stTodos app
        return $ Map.elems $ Map.filter (\t -> todoUserId t == uid) todos
      let sortedTodos = sortOn todoId todosList
      S.json $ map toTodoResponse sortedTodos

handlePostTodo :: AppState -> S.ActionM ()
handlePostTodo app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right uid -> do
      req <- S.jsonData :: S.ActionM TodoRequest
      
      let mTitle = reqTitle req
      case mTitle of
        Nothing -> jsonError status400 "Title is required"
        Just t | T.null t -> jsonError status400 "Title is required"
        Just title -> do
          let desc = fromMaybe "" (reqDescription req)
          now <- liftIO getCurrentTime
          newTodo <- liftIO $ atomically $ do
            tid <- readTVar $ stNextTodoId app
            writeTVar (stNextTodoId app) (tid + 1)
            let todo = Todo tid uid title desc False now now
            modifyTVar (stTodos app) (Map.insert tid todo)
            return todo
          S.status status201
          S.json $ toTodoResponse newTodo

handleGetTodo :: AppState -> S.ActionM ()
handleGetTodo app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right uid -> do
      mTid <- getPathParam 1
      case mTid >>= readMaybe . T.unpack :: Maybe Int of
        Nothing -> jsonError status404 "Todo not found"
        Just tid -> do
          todo <- liftIO $ atomically $ do
            todos <- readTVar $ stTodos app
            case Map.lookup tid todos of
              Just t | todoUserId t == uid -> return (Right t)
              _otherwise -> return (Left "Todo not found")
          case todo of
            Left _ -> jsonError status404 "Todo not found"
            Right t -> S.json $ toTodoResponse t

handlePutTodo :: AppState -> S.ActionM ()
handlePutTodo app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right uid -> do
      mTid <- getPathParam 1
      case mTid >>= readMaybe . T.unpack :: Maybe Int of
        Nothing -> jsonError status404 "Todo not found"
        Just tid -> do
          req <- S.jsonData :: S.ActionM TodoUpdateRequest
          
          res <- liftIO $ do
            now <- getCurrentTime
            atomically $ do
              todos <- readTVar $ stTodos app
              case Map.lookup tid todos of
                Just t | todoUserId t == uid -> do
                  let newTitle = fromMaybe (todoTitle t) (updTitle req)
                  if T.null newTitle
                    then return (Left "Title is required")
                    else do
                      let newDesc = fromMaybe (todoDescription t) (updDescription req)
                      let newComp = fromMaybe (todoCompleted t) (updCompleted req)
                      let updatedTodo = t 
                            { todoTitle = newTitle
                            , todoDescription = newDesc
                            , todoCompleted = newComp
                            , todoUpdatedAt = now
                            }
                      modifyTVar (stTodos app) (Map.insert tid updatedTodo)
                      return (Right updatedTodo)
                _otherwise -> return (Left "Todo not found")
              
          case res of
            Left err -> 
              if err == "Title is required"
                then jsonError status400 err
                else jsonError status404 err
            Right t -> S.json $ toTodoResponse t

handleDeleteTodo :: AppState -> S.ActionM ()
handleDeleteTodo app = do
  authRes <- requireAuth app
  case authRes of
    Left err -> jsonError status401 err
    Right uid -> do
      mTid <- getPathParam 1
      case mTid >>= readMaybe . T.unpack :: Maybe Int of
        Nothing -> jsonError status404 "Todo not found"
        Just tid -> do
          res <- liftIO $ atomically $ do
            todos <- readTVar $ stTodos app
            case Map.lookup tid todos of
              Just t | todoUserId t == uid -> do
                modifyTVar (stTodos app) (Map.delete tid)
                return (Right ())
              _otherwise -> return (Left "Todo not found")
          case res of
            Left _ -> jsonError status404 "Todo not found"
            Right () -> S.status status204

-- | Initialization
newAppState :: IO AppState
newAppState = do
  nextUserId <- newTVarIO 1
  nextTodoId <- newTVarIO 1
  users <- newTVarIO Map.empty
  userByName <- newTVarIO Map.empty
  todos <- newTVarIO Map.empty
  sessions <- newTVarIO Map.empty
  return AppState { stNextUserId = nextUserId
                  , stNextTodoId = nextTodoId
                  , stUsers = users
                  , stUserByName = userByName
                  , stTodos = todos
                  , stSessions = sessions
                  }

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
               ["--port", p] -> read p
               _ -> 3000
  app <- newAppState
  S.scotty port $ do
    S.post "/register" $ handleRegister app
    S.post "/login" $ handleLogin app
    S.post "/logout" $ handleLogout app
    S.get "/me" $ handleMe app
    S.put "/password" $ handlePassword app
    S.get "/todos" $ handleGetTodos app
    S.post "/todos" $ handlePostTodo app
    S.get "/todos/:id" $ handleGetTodo app
    S.put "/todos/:id" $ handlePutTodo app
    S.delete "/todos/:id" $ handleDeleteTodo app
