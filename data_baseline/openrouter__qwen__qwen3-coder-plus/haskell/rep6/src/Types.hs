{-# LANGUAGE OverloadedStrings #-}
module Types where

import Data.Aeson
import Data.Time.Format
import Data.Time.Clock
import Text.Read (readMaybe)

data User = User
  { userId :: Int
  , username :: String
  } deriving (Show, Eq)

data Todo = Todo
  { todoId :: Int
  , title :: String
  , description :: String
  , completed :: Bool
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  } deriving (Show, Eq)

instance ToJSON User where
  toJSON u = object [ "id" .= userId u
                    , "username" .= username u
                    ]

instance FromJSON User where
  parseJSON = withObject "User" $ \v -> User
    <$> v .: "id"
    <*> v .: "username"

instance ToJSON Todo where
  toJSON t = object [ "id" .= todoId t
                    , "title" .= title t
                    , "description" .= description t
                    , "completed" .= completed t
                    , "created_at" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (createdAt t)
                    , "updated_at" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (updatedAt t)
                    ]

data LoginRequest = LoginRequest
  { loginUsername :: String
  , loginPassword :: String
  } deriving (Show, Eq)

instance FromJSON LoginRequest where
  parseJSON = withObject "LoginRequest" $ \v -> LoginRequest
    <$> v .: "username"
    <*> v .: "password"

data RegisterRequest = RegisterRequest
  { registerUsername :: String
  , registerPassword :: String
  } deriving (Show, Eq)

instance FromJSON RegisterRequest where
  parseJSON = withObject "RegisterRequest" $ \v -> RegisterRequest
    <$> v .: "username"
    <*> v .: "password"

data ChangePasswordRequest = ChangePasswordRequest
  { oldPassword :: String
  , newPassword :: String
  } deriving (Show, Eq)

instance FromJSON ChangePasswordRequest where
  parseJSON = withObject "ChangePasswordRequest" $ \v -> ChangePasswordRequest
    <$> v .: "old_password"
    <*> v .: "new_password"

data UpdateTodoRequest = UpdateTodoRequest
  { updateTitle :: Maybe String
  , updateDescription :: Maybe String
  , updateCompleted :: Maybe Bool
  } deriving (Show, Eq)

instance FromJSON UpdateTodoRequest where
  parseJSON = withObject "UpdateTodoRequest" $ \v -> UpdateTodoRequest
    <$> v .:? "title"
    <*> v .:? "description"
    <*> v .:? "completed"
    
data CreateTodoRequest = CreateTodoRequest
  { createTitle :: String
  , createDescription :: String
  } deriving (Show, Eq)

instance FromJSON CreateTodoRequest where
  parseJSON = withObject "CreateTodoRequest" $ \v -> CreateTodoRequest
    <$> v .: "title"
    <*> v .: "description"

data ErrorResponse = ErrorResponse
  { errorText :: String
  } deriving (Show, Eq)

instance ToJSON ErrorResponse where
  toJSON e = object ["error" .= errorText e]