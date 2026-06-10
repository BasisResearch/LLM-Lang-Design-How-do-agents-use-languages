{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.Aeson as A
import Data.Aeson ((.=), withObject, (.:?))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Time (getCurrentTime, utcToZonedTime, utc)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import System.Random (randomRIO)
import Control.Monad (when, unless, replicateM)
import Data.List (sortOn)
import GHC.Generics (Generic)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Web.Scotty
import Network.HTTP.Types (Status, status201, status204, status400, status401, status404, status409)
import qualified Crypto.KDF.PBKDF2 as PBKDF2

-- | Data Types
data User = User
  { userId :: Int
  , username :: T.Text
  , userSalt :: BS.ByteString
  , userPasswordHash :: BS.ByteString
  } deriving (Show, Eq)

data Todo = Todo
  { todoId :: Int
  , todoUserId :: Int
  , todoTitle :: T.Text
  , todoDescription :: T.Text
  , todoCompleted :: Bool
  , todoCreatedAt :: T.Text
  , todoUpdatedAt :: T.Text
  } deriving (Show, Eq)

instance A.ToJSON Todo where
  toJSON (Todo tid _ title desc completed createdAt updatedAt) =
    A.object [ "id" .= tid
             , "title" .= title
             , "description" .= desc
             , "completed" .= completed
             , "created_at" .= createdAt
             , "updated_at" .= updatedAt
             ]

data AppState = AppState
  { stUsers :: IORef (M.Map Int User)
  , stUsersByName :: IORef (M.Map T.Text User)
  , stTodos :: IORef (M.Map Int Todo)
  , stSessions :: IORef (M.Map T.Text Int)
  , stNextUserId :: IORef Int
  , stNextTodoId :: IORef Int
  }

newAppState :: IO AppState
newAppState = do
  stUsers <- newIORef M.empty
  stUsersByName <- newIORef M.empty
  stTodos <- newIORef M.empty
  stSessions <- newIORef M.empty
  stNextUserId <- newIORef 1
  stNextTodoId <- newIORef 1
  return AppState {..}

-- | Request/Response Types
data ErrorResponse = ErrorResponse { error :: T.Text } deriving (Generic)
instance A.ToJSON ErrorResponse

data UserResponse = UserResponse { urId :: Int, urUsername :: T.Text } deriving (Generic)
instance A.ToJSON UserResponse

data RegisterRequest = RegisterRequest 
  { regUsername :: Maybe T.Text
  , regPassword :: Maybe T.Text
  }

instance A.FromJSON RegisterRequest where
  parseJSON = withObject "RegisterRequest" $ \o ->
    RegisterRequest <$> o .:? "username" <*> o .:? "password"

data LoginRequest = LoginRequest 
  { logUsername :: Maybe T.Text
  , logPassword :: Maybe T.Text
  }

instance A.FromJSON LoginRequest where
  parseJSON = withObject "LoginRequest" $ \o ->
    LoginRequest <$> o .:? "username" <*> o .:? "password"

data PasswordChangeRequest = PasswordChangeRequest 
  { pcOldPassword :: Maybe T.Text
  , pcNewPassword :: Maybe T.Text
  }

instance A.FromJSON PasswordChangeRequest where
  parseJSON = withObject "PasswordChangeRequest" $ \o ->
    PasswordChangeRequest <$> o .:? "old_password" <*> o .:? "new_password"

data CreateTodoRequest = CreateTodoRequest 
  { ctTitle :: Maybe T.Text
  , ctDescription :: Maybe T.Text
  }

instance A.FromJSON CreateTodoRequest where
  parseJSON = withObject "CreateTodoRequest" $ \o ->
    CreateTodoRequest <$> o .:? "title" <*> o .:? "description"

data UpdateTodoRequest = UpdateTodoRequest 
  { utTitle :: Maybe T.Text
  , utDescription :: Maybe T.Text
  , utCompleted :: Maybe Bool
  }

instance A.FromJSON UpdateTodoRequest where
  parseJSON = withObject "UpdateTodoRequest" $ \o ->
    UpdateTodoRequest <$> o .:? "title" <*> o .:? "description" <*> o .:? "completed"

-- | Helpers
isValidUsername :: T.Text -> Bool
isValidUsername t = 
  let len = T.length t
      isAsciiAlphaNum c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
  in len >= 3 && len <= 50 && T.all isAsciiAlphaNum t

getCurrentTimeIso :: IO T.Text
getCurrentTimeIso = do
  now <- getCurrentTime
  let utcTime = utcToZonedTime utc now
  return $ T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" utcTime

generateUUID :: IO String
generateUUID = do
  uuid <- nextRandom
  return $ toString uuid

hashPassword :: T.Text -> IO (BS.ByteString, BS.ByteString)
hashPassword pass = do
  salt <- BS.pack <$> replicateM 16 (randomRIO (0, 255))
  let passBs = BSC.pack (T.unpack pass)
      params = PBKDF2.Parameters 10000 32
  return (salt, PBKDF2.fastPBKDF2_SHA256 params salt passBs)

verifyPassword :: T.Text -> BS.ByteString -> BS.ByteString -> Bool
verifyPassword pass salt storedHash =
  let passBs = BSC.pack (T.unpack pass)
      params = PBKDF2.Parameters 10000 32
  in PBKDF2.fastPBKDF2_SHA256 params salt passBs == storedHash

abort :: Status -> T.Text -> ActionM a
abort s msg = do
  status s
  json (ErrorResponse msg)
  finish

requireAuth :: AppState -> ActionM Int
requireAuth st = do
  mSession <- getCookie "session_id"
  case mSession of
    Nothing -> abort status401 "Authentication required"
    Just sid -> do
      sessions <- liftIO $ readIORef (stSessions st)
      case M.lookup sid sessions of
        Nothing -> abort status401 "Authentication required"
        Just uid -> return uid

-- | Application
appRoutes :: AppState -> ScottyM ()
appRoutes st = do
  post "/register" $ do
    req <- jsonData :: ActionM RegisterRequest
    let uname = T.strip $ fromMaybe "" (regUsername req)
        pass = fromMaybe "" (regPassword req)
    
    when (not (isValidUsername uname)) $ abort status400 "Invalid username"
    when (T.length pass < 8) $ abort status400 "Password too short"
    
    users <- liftIO $ readIORef (stUsersByName st)
    when (M.member uname users) $ abort status409 "Username already exists"
    
    (salt, hash) <- liftIO $ hashPassword pass
    newUser <- liftIO $ do
      uid <- readIORef (stNextUserId st)
      let user = User uid uname salt hash
      modifyIORef' (stUsers st) (M.insert uid user)
      modifyIORef' (stUsersByName st) (M.insert uname user)
      modifyIORef' (stNextUserId st) (+1)
      return user
    
    status status201
    json $ UserResponse (userId newUser) (username newUser)

  post "/login" $ do
    req <- jsonData :: ActionM LoginRequest
    let uname = fromMaybe "" (logUsername req)
        pass = fromMaybe "" (logPassword req)
    
    users <- liftIO $ readIORef (stUsersByName st)
    case M.lookup uname users of
      Nothing -> abort status401 "Invalid credentials"
      Just u -> do
        if verifyPassword pass (userSalt u) (userPasswordHash u)
          then do
            token <- liftIO generateUUID
            liftIO $ modifyIORef' (stSessions st) (M.insert (T.pack token) (userId u))
            setHeader "Set-Cookie" (LT.pack ("session_id=" ++ token ++ "; Path=/; HttpOnly"))
            json $ UserResponse (userId u) (username u)
          else abort status401 "Invalid credentials"

  post "/logout" $ do
    _uid <- requireAuth st
    sid <- getCookie "session_id"
    case sid of
      Just s -> liftIO $ modifyIORef' (stSessions st) (M.delete s)
      Nothing -> return ()
    json $ A.object []

  get "/me" $ do
    uid <- requireAuth st
    users <- liftIO $ readIORef (stUsers st)
    case M.lookup uid users of
      Just u -> json $ UserResponse (userId u) (username u)
      Nothing -> abort status401 "Authentication required"

  put "/password" $ do
    uid <- requireAuth st
    req <- jsonData :: ActionM PasswordChangeRequest
    users <- liftIO $ readIORef (stUsers st)
    case M.lookup uid users of
      Just u -> do
        let oldPass = fromMaybe "" (pcOldPassword req)
            newPass = fromMaybe "" (pcNewPassword req)
        unless (verifyPassword oldPass (userSalt u) (userPasswordHash u)) $ 
          abort status401 "Invalid credentials"
        when (T.length newPass < 8) $ abort status400 "Password too short"
        
        (newSalt, newHash) <- liftIO $ hashPassword newPass
        liftIO $ do
          modifyIORef' (stUsers st) (M.adjust (\user -> user { userSalt = newSalt, userPasswordHash = newHash }) uid)
          modifyIORef' (stUsersByName st) (M.adjust (\user -> user { userSalt = newSalt, userPasswordHash = newHash }) (username u))
        json $ A.object []
      Nothing -> abort status401 "Authentication required"

  get "/todos" $ do
    uid <- requireAuth st
    todos <- liftIO $ readIORef (stTodos st)
    let myTodos = M.elems $ M.filter (\t -> todoUserId t == uid) todos
    let sorted = sortOn todoId myTodos
    json sorted

  post "/todos" $ do
    uid <- requireAuth st
    req <- jsonData :: ActionM CreateTodoRequest
    let mRawTitle = ctTitle req
    case mRawTitle of
      Nothing -> abort status400 "Title is required"
      Just rawTitle -> do
        let cleanTitle = T.strip rawTitle
        when (T.null cleanTitle) $ abort status400 "Title is required"
        
        let desc = fromMaybe "" (ctDescription req)
        now <- liftIO getCurrentTimeIso
        newTodo <- liftIO $ do
          tid <- readIORef (stNextTodoId st)
          let todo = Todo tid uid cleanTitle desc False now now
          modifyIORef' (stTodos st) (M.insert tid todo)
          modifyIORef' (stNextTodoId st) (+1)
          return todo
        status status201
        json newTodo

  get "/todos/:id" $ do
    uid <- requireAuth st
    tidStr <- pathParam "id"
    case readMaybe (T.unpack tidStr) of
      Nothing -> abort status404 "Todo not found"
      Just tid -> do
        todos <- liftIO $ readIORef (stTodos st)
        case M.lookup tid todos of
          Just t | todoUserId t == uid -> json t
          _ -> abort status404 "Todo not found"

  put "/todos/:id" $ do
    uid <- requireAuth st
    tidStr <- pathParam "id"
    req <- jsonData :: ActionM UpdateTodoRequest
    case readMaybe (T.unpack tidStr) of
      Nothing -> abort status404 "Todo not found"
      Just tid -> do
        todos <- liftIO $ readIORef (stTodos st)
        case M.lookup tid todos of
          Just t | todoUserId t == uid -> do
            case utTitle req of
              Just t' | T.null (T.strip t') -> abort status400 "Title is required"
              _ -> do
                now <- liftIO getCurrentTimeIso
                let newT = t { todoTitle = fromMaybe (todoTitle t) (T.strip <$> utTitle req)
                             , todoDescription = fromMaybe (todoDescription t) (utDescription req)
                             , todoCompleted = fromMaybe (todoCompleted t) (utCompleted req)
                             , todoUpdatedAt = now
                             }
                liftIO $ modifyIORef' (stTodos st) (M.insert tid newT)
                json newT
          _ -> abort status404 "Todo not found"

  delete "/todos/:id" $ do
    uid <- requireAuth st
    tidStr <- pathParam "id"
    case readMaybe (T.unpack tidStr) of
      Nothing -> abort status404 "Todo not found"
      Just tid -> do
        todos <- liftIO $ readIORef (stTodos st)
        case M.lookup tid todos of
          Just t | todoUserId t == uid -> do
            liftIO $ modifyIORef' (stTodos st) (M.delete tid)
            status status204
            finish
          _ -> abort status404 "Todo not found"

parseArgs :: [String] -> Int
parseArgs ("--port":p:_) = read p
parseArgs (_:rest) = parseArgs rest
parseArgs _ = 8080

main :: IO ()
main = do
  args <- getArgs
  let port = parseArgs args
  
  when (port < 1 || port > 65535) $ do
    putStrLn "Invalid port"
    exitFailure
  
  st <- newAppState
  putStrLn $ "Starting server on port " ++ show port
  scotty port (appRoutes st)
