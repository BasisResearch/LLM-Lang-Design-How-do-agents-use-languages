{-# LANGUAGE OverloadedStrings #-}

module Lib where

import qualified Data.Text as T
import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import Data.Aeson (ToJSON, FromJSON, encode)
import Data.Aeson.TH (deriveJSON, defaultOptions)
import Data.Time (getCurrentTime, formatTime)
import Data.Time.Format (defaultTimeLocale)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent.STM
import qualified Data.Map as Map
import Crypto.Hash (hashWith, SHA256)
import Data.ByteArray.Encoding (Base16, convertToBase)
import Data.String (fromString)
import qualified Data.ByteString.Char8 as BS

-- Data types
data User = User 
  { userId :: Int
  , username :: String 
  , passwordHash :: PasswordHash
  } deriving (Show)

instance ToJSON User where
  toJSON u = Data.Aeson.object ["id" .= userId u, "username" .= username u]

deriveJSON defaultOptions ''User

data Todo = Todo
  { todoId :: Int
  , todoTitle :: String
  , todoDescription :: String
  , todoCompleted :: Bool
  , createdAt :: String
  , updatedAt :: String
  , ownerId :: Int  -- Reference to user who owns this todo
  } deriving (Show, Eq)

instance ToJSON Todo

deriveJSON defaultOptions ''Todo

data RegisterRequest = RegisterRequest 
  { regUsername :: T.Text
  , regPassword :: T.Text
  } deriving (Show)

instance FromJSON RegisterRequest

deriveJSON defaultOptions ''RegisterRequest

data LoginRequest = LoginRequest
  { loginUsername :: T.Text 
  , loginPassword :: T.Text
  } deriving (Show)

instance FromJSON LoginRequest

deriveJSON defaultOptions ''LoginRequest

data ChangePasswordRequest = ChangePasswordRequest
  { oldPassword :: T.Text
  , newPassword :: T.Text
  } deriving (Show)

instance FromJSON ChangePasswordRequest

deriveJSON defaultOptions ''ChangePasswordRequest

data TodoUpdateRequest = TodoUpdateRequest
  { updateTitle :: Maybe T.Text
  , updateDescription :: Maybe T.Text
  , updateCompleted :: Maybe Bool
  } deriving (Show)

instance FromJSON TodoUpdateRequest

deriveJSON defaultOptions ''TodoUpdateRequest

type PasswordHash = String

-- | Hash password using SHA256
hashPassword :: String -> String
hashPassword p = convertToBase Base16 $ hashWith SHA256 $ BS.pack p

-- | Validate username format (3-50 chars, alphanumeric and underscore)
validateUsername :: String -> Bool
validateUsername username = 
  length username >= 3 && length username <= 50 && all isValidChar username
  where
    isValidChar c = c `elem` ['a'..'z'] || c `elem` ['A'..'Z'] || c `elem` ['0'..'9'] || c == '_'

-- | Get current ISO8601 formatted time
getISOString :: IO String
getISOString = do
  now <- getCurrentTime
  return $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

-- | Application State
data AppState = AppState
  { users :: TVar [(Int, User)]           -- List of (UserId, User) pairs
  , todos :: TVar [(Int, Todo)]           -- List of (TodoId, Todo) pairs  
  , sessions :: TVar (Map.Map String Int)  -- Map sessionID to user ID
  , nextUserId :: TVar Int               -- Counter for next user ID
  , nextTodoId :: TVar Int               -- Counter for next todo ID
  }

-- | Initialize application state
initAppState :: IO AppState
initAppState = do
  usersVar <- newTVarIO []
  todosVar <- newTVarIO []
  sessionsVar <- newTVarIO Map.empty
  userIdCounter <- newTVarIO 1
  todoIdCounter <- newTVarIO 1
  return $ AppState usersVar todosVar sessionsVar userIdCounter todoIdCounter