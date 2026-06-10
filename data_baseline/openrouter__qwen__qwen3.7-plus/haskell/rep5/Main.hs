{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Main where

import qualified Data.Map.Strict as M
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.Aeson
import GHC.Generics
import Web.Scotty
import Network.Wai (pathInfo)
import Network.HTTP.Types (Status, status201, status204, status400, status401, status404, status409)
import qualified Data.UUID.V4 as UUID
import qualified Data.UUID as UUID
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import qualified Crypto.Hash as Hash
import qualified Data.ByteString.Char8 as C8
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Text.Read (readMaybe)
import Data.List (sortBy, isPrefixOf)
import System.Environment (getArgs)

data ServerState = ServerState
  { stNextUserId :: Int
  , stUsers :: M.Map Int User
  , stUsersByName :: M.Map Text Int
  , stNextTodoId :: Int
  , stTodos :: M.Map Int Todo
  , stSessions :: M.Map Text Int
  } deriving (Show)

data User = User
  { uId :: Int
  , uUsername :: Text
  , uPasswordHash :: Text
  } deriving (Show, Generic)

data Todo = Todo
  { tId :: Int
  , tUserId :: Int
  , tTitle :: Text
  , tDescription :: Text
  , tCompleted :: Bool
  , tCreatedAt :: Text
  , tUpdatedAt :: Text
  } deriving (Show, Generic)

initialState :: ServerState
initialState = ServerState
  { stNextUserId = 1
  , stUsers = M.empty
  , stUsersByName = M.empty
  , stNextTodoId = 1
  , stTodos = M.empty
  , stSessions = M.empty
  }

instance ToJSON User where
  toJSON u = object ["id" .= uId u, "username" .= uUsername u]

instance ToJSON Todo where
  toJSON t = object
    [ "id" .= tId t
    , "title" .= tTitle t
    , "description" .= tDescription t
    , "completed" .= tCompleted t
    , "created_at" .= tCreatedAt t
    , "updated_at" .= tUpdatedAt t
    ]

data RegisterReq = RegisterReq
  { reqUsername :: Text
  , reqPassword :: Text
  } deriving (Generic)

instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \v -> RegisterReq
    <$> v .: "username"
    <*> v .: "password"

data LoginReq = LoginReq
  { reqLoginUsername :: Text
  , reqLoginPassword :: Text
  } deriving (Generic)

instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \v -> LoginReq
    <$> v .: "username"
    <*> v .: "password"

data PasswordChangeReq = PasswordChangeReq
  { reqOldPassword :: Text
  , reqNewPassword :: Text
  } deriving (Generic)

instance FromJSON PasswordChangeReq where
  parseJSON = withObject "PasswordChangeReq" $ \v -> PasswordChangeReq
    <$> v .: "old_password"
    <*> v .: "new_password"

data CreateTodoReq = CreateTodoReq
  { reqTitle :: Maybe Text
  , reqDescription :: Maybe Text
  } deriving (Generic)

instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \v -> CreateTodoReq
    <$> v .:? "title"
    <*> v .:? "description"

data TodoReq = TodoReq
  { reqTodoTitle :: Maybe Text
  , reqTodoDescription :: Maybe Text
  , reqTodoCompleted :: Maybe Bool
  } deriving (Generic)

instance FromJSON TodoReq where
  parseJSON = withObject "TodoReq" $ \v -> TodoReq
    <$> v .:? "title"
    <*> v .:? "description"
    <*> v .:? "completed"

hashPassword :: Text -> Text
hashPassword pwd = T.pack $ show (Hash.hash (C8.pack $ T.unpack pwd) :: Hash.Digest Hash.SHA256)

isValidUsername :: Text -> Bool
isValidUsername u =
  let len = T.length u
      validChars = T.all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') u
  in len >= 3 && len <= 50 && validChars

getCurrentTimeText :: IO Text
getCurrentTimeText = do
  now <- getCurrentTime
  let fmt = "%Y-%m-%dT%H:%M:%SZ"
  return $ T.pack $ formatTime defaultTimeLocale fmt now

jsonError :: Status -> Text -> ActionM ()
jsonError status' msg = do
  status status'
  json $ object ["error" .= msg]

requireAuth :: IORef ServerState -> ActionM (Maybe Int)
requireAuth stateRef = do
  mSession <- getCookie "session_id"
  case mSession of
    Nothing -> return Nothing
    Just sid -> do
      st <- liftIO $ readIORef stateRef
      case M.lookup sid (stSessions st) of
        Nothing -> return Nothing
        Just uid -> return (Just uid)

getTodoId :: ActionM (Maybe Int)
getTodoId = do
  req <- request
  let segments = pathInfo req
  case segments of
    ["todos", tidStr] -> return $ readMaybe (T.unpack tidStr)
    _ -> return Nothing

parseArgs :: [String] -> [(String, String)]
parseArgs [] = []
parseArgs ("--port":p:rest) = ("port", p) : parseArgs rest
parseArgs (arg:rest)
  | "--port=" `isPrefixOf` arg = ("port", drop 6 arg) : parseArgs rest
  | otherwise = parseArgs rest

main :: IO ()
main = do
  args <- getArgs
  let port = case lookup "port" (parseArgs args) of
               Just p -> read p
               Nothing -> 8080
  stateRef <- newIORef initialState
  scotty port $ do
    post "/register" $ do
      req <- jsonData :: ActionM RegisterReq
      let uname = reqUsername req
          pwd = reqPassword req
      if not (isValidUsername uname)
        then jsonError status400 "Invalid username"
        else if T.length pwd < 8
          then jsonError status400 "Password too short"
          else do
            st <- liftIO $ readIORef stateRef
            if M.member uname (stUsersByName st)
              then jsonError status409 "Username already exists"
              else do
                let newId = stNextUserId st
                    newUser = User newId uname (hashPassword pwd)
                    newState = st
                      { stNextUserId = newId + 1
                      , stUsers = M.insert newId newUser (stUsers st)
                      , stUsersByName = M.insert uname newId (stUsersByName st)
                      }
                liftIO $ writeIORef stateRef newState
                status status201
                json (object ["id" .= uId newUser, "username" .= uUsername newUser])

    post "/login" $ do
      req <- jsonData :: ActionM LoginReq
      let uname = reqLoginUsername req
          pwd = reqLoginPassword req
      st <- liftIO $ readIORef stateRef
      case M.lookup uname (stUsersByName st) of
        Nothing -> jsonError status401 "Invalid credentials"
        Just uid -> do
          let user = stUsers st M.! uid
          if uPasswordHash user == hashPassword pwd
            then do
              uuid <- liftIO UUID.nextRandom
              let token = T.pack (UUID.toString uuid)
                  newState = st { stSessions = M.insert token uid (stSessions st) }
              liftIO $ writeIORef stateRef newState
              setHeader "Set-Cookie" ("session_id=" <> LT.fromStrict token <> "; Path=/; HttpOnly")
              json (object ["id" .= uId user, "username" .= uUsername user])
            else jsonError status401 "Invalid credentials"

    post "/logout" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just _uid -> do
          mSession <- getCookie "session_id"
          case mSession of
            Just sid -> do
              st <- liftIO $ readIORef stateRef
              let newState = st { stSessions = M.delete sid (stSessions st) }
              liftIO $ writeIORef stateRef newState
            Nothing -> return ()
          json (object [] :: Value)

    get "/me" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid -> do
          st <- liftIO $ readIORef stateRef
          case M.lookup uid (stUsers st) of
            Just user -> json (object ["id" .= uId user, "username" .= uUsername user])
            Nothing -> jsonError status401 "Authentication required"

    put "/password" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid -> do
          req <- jsonData :: ActionM PasswordChangeReq
          st <- liftIO $ readIORef stateRef
          case M.lookup uid (stUsers st) of
            Just user -> do
              if uPasswordHash user /= hashPassword (reqOldPassword req)
                then jsonError status401 "Invalid credentials"
                else if T.length (reqNewPassword req) < 8
                  then jsonError status400 "Password too short"
                  else do
                    let newUser = user { uPasswordHash = hashPassword (reqNewPassword req) }
                        newState = st { stUsers = M.insert uid newUser (stUsers st) }
                    liftIO $ writeIORef stateRef newState
                    json (object [] :: Value)
            Nothing -> jsonError status401 "Authentication required"

    get "/todos" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid -> do
          st <- liftIO $ readIORef stateRef
          let userTodos = M.elems $ M.filter (\t -> tUserId t == uid) (stTodos st)
              sortedTodos = sortBy (\a b -> compare (tId a) (tId b)) userTodos
          json sortedTodos

    post "/todos" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid -> do
          req <- jsonData :: ActionM CreateTodoReq
          case reqTitle req of
            Nothing -> jsonError status400 "Title is required"
            Just title -> do
              if T.null title
                then jsonError status400 "Title is required"
                else do
                  st <- liftIO $ readIORef stateRef
                  let newId = stNextTodoId st
                  timeText <- liftIO getCurrentTimeText
                  let newTodo = Todo
                        { tId = newId
                        , tUserId = uid
                        , tTitle = title
                        , tDescription = fromMaybe "" (reqDescription req)
                        , tCompleted = False
                        , tCreatedAt = timeText
                        , tUpdatedAt = timeText
                        }
                      newState = st
                        { stNextTodoId = newId + 1
                        , stTodos = M.insert newId newTodo (stTodos st)
                        }
                  liftIO $ writeIORef stateRef newState
                  status status201
                  json newTodo

    get "/todos/:id" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid -> do
          mTid <- getTodoId
          case mTid of
            Nothing -> jsonError status404 "Todo not found"
            Just tid -> do
              st <- liftIO $ readIORef stateRef
              case M.lookup tid (stTodos st) of
                Just todo | tUserId todo == uid -> json todo
                _ -> jsonError status404 "Todo not found"

    put "/todos/:id" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid -> do
          mTid <- getTodoId
          case mTid of
            Nothing -> jsonError status404 "Todo not found"
            Just tid -> do
              st <- liftIO $ readIORef stateRef
              case M.lookup tid (stTodos st) of
                Just todo | tUserId todo == uid -> do
                  mReq <- jsonData :: ActionM (Maybe TodoReq)
                  let req = fromMaybe (TodoReq Nothing Nothing Nothing) mReq
                  case reqTodoTitle req of
                    Just t | T.null t -> jsonError status400 "Title is required"
                    _ -> do
                      timeText <- liftIO getCurrentTimeText
                      let newTodo = todo
                            { tTitle = fromMaybe (tTitle todo) (reqTodoTitle req)
                            , tDescription = fromMaybe (tDescription todo) (reqTodoDescription req)
                            , tCompleted = fromMaybe (tCompleted todo) (reqTodoCompleted req)
                            , tUpdatedAt = timeText
                            }
                          newState = st { stTodos = M.insert tid newTodo (stTodos st) }
                      liftIO $ writeIORef stateRef newState
                      json newTodo
                _ -> jsonError status404 "Todo not found"

    delete "/todos/:id" $ do
      mUid <- requireAuth stateRef
      case mUid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid -> do
          mTid <- getTodoId
          case mTid of
            Nothing -> jsonError status404 "Todo not found"
            Just tid -> do
              st <- liftIO $ readIORef stateRef
              case M.lookup tid (stTodos st) of
                Just todo | tUserId todo == uid -> do
                  let newState = st { stTodos = M.delete tid (stTodos st) }
                  liftIO $ writeIORef stateRef newState
                  status status204
                _ -> jsonError status404 "Todo not found"
