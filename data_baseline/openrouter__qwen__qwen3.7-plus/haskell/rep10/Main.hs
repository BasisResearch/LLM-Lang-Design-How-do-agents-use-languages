{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

import Web.Scotty
import qualified Network.HTTP.Types as HT
import Data.Aeson
import GHC.Generics
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import Control.Concurrent.STM
import Data.Time.Clock
import Data.Time.Format
import Data.UUID.V4
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlphaNum)
import Crypto.Hash (hash, SHA256, Digest)
import Data.Maybe (fromMaybe)
import Text.Read (readMaybe)
import Data.List (find, sortBy)
import Data.Ord (comparing)
import System.Environment (getArgs)

data User = User
  { userId :: Int
  , username :: Text
  , passwordHash :: Text
  } deriving (Show, Generic)

data Todo = Todo
  { todoId :: Int
  , ownerId :: Int
  , title :: Text
  , description :: Text
  , completed :: Bool
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  } deriving (Show, Generic)

data AppState = AppState
  { stateUsersByName :: TVar (M.Map Text User)
  , stateUsersById :: TVar (IM.IntMap User)
  , stateNextUserId :: TVar Int
  , stateSessions :: TVar (M.Map Text Int)
  , stateTodos :: TVar (IM.IntMap Todo)
  , stateNextTodoId :: TVar Int
  }

initAppState :: IO AppState
initAppState = do
  usersByName <- newTVarIO M.empty
  usersById <- newTVarIO IM.empty
  nextUserId <- newTVarIO 1
  sessions <- newTVarIO M.empty
  todos <- newTVarIO IM.empty
  nextTodoId <- newTVarIO 1
  return AppState
    { stateUsersByName = usersByName
    , stateUsersById = usersById
    , stateNextUserId = nextUserId
    , stateSessions = sessions
    , stateTodos = todos
    , stateNextTodoId = nextTodoId
    }

hashPassword :: Text -> Text -> Text
hashPassword username pass =
  let salt = "SUPER_SECRET_SALT_123"
      input = TE.encodeUtf8 (salt <> ":" <> username <> ":" <> pass)
      digest = hash input :: Digest SHA256
  in T.pack (show digest)

jsonError :: Int -> Text -> ActionM a
jsonError sc msg = do
  status (HT.mkStatus sc "")
  addHeader "Content-Type" "application/json"
  raw (encode $ object ["error" .= msg])
  finish

jsonWithStatus :: ToJSON a => Int -> a -> ActionM ()
jsonWithStatus sc val = do
  status (HT.mkStatus sc "")
  addHeader "Content-Type" "application/json"
  raw (encode val)

getCookieValue :: Text -> ActionM (Maybe Text)
getCookieValue name = do
  mCookie <- getCookie name
  return mCookie

requireAuth :: AppState -> ActionM Int
requireAuth appState = do
  mToken <- getCookieValue "session_id"
  case mToken of
    Nothing -> jsonError 401 "Authentication required"
    Just token -> do
      sessions <- liftIO $ readTVarIO (stateSessions appState)
      case M.lookup token sessions of
        Nothing -> jsonError 401 "Authentication required"
        Just uid -> return uid

todoToJSON :: Todo -> Value
todoToJSON t = object
  [ "id" .= todoId t
  , "title" .= title t
  , "description" .= description t
  , "completed" .= completed t
  , "created_at" .= formatTimeTodo (createdAt t)
  , "updated_at" .= formatTimeTodo (updatedAt t)
  ]

formatTimeTodo :: UTCTime -> Text
formatTimeTodo t = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t

main :: IO ()
main = do
  appState <- initAppState
  portArg <- getPortArg
  scotty portArg $ do
    
    post "/register" $ do
      bodyData <- body
      case eitherDecode bodyData of
        Left _ -> jsonError 400 "Invalid username"
        Right (RegisterReq uname pass) -> do
          if not (T.length uname >= 3 && T.length uname <= 50) then
            jsonError 400 "Invalid username"
          else if not (T.all (\c -> isAlphaNum c || c == '_') uname) then
            jsonError 400 "Invalid username"
          else if T.length pass < 8 then
            jsonError 400 "Password too short"
          else do
            usersMap <- liftIO $ readTVarIO (stateUsersByName appState)
            if M.member uname usersMap then
              jsonError 409 "Username already exists"
            else do
              uid <- liftIO $ atomically $ do
                uid <- readTVar (stateNextUserId appState)
                writeTVar (stateNextUserId appState) (uid + 1)
                let newUser = User uid uname (hashPassword uname pass)
                modifyTVar (stateUsersByName appState) (M.insert uname newUser)
                modifyTVar (stateUsersById appState) (IM.insert uid newUser)
                return uid
              jsonWithStatus 201 $ object ["id" .= uid, "username" .= uname]

    post "/login" $ do
      bodyData <- body
      case eitherDecode bodyData of
        Left _ -> jsonError 401 "Invalid credentials"
        Right (LoginReq uname pass) -> do
          usersMap <- liftIO $ readTVarIO (stateUsersByName appState)
          case M.lookup uname usersMap of
            Nothing -> jsonError 401 "Invalid credentials"
            Just user -> 
              if passwordHash user == hashPassword uname pass then do
                token <- liftIO $ show <$> nextRandom
                liftIO $ atomically $ modifyTVar (stateSessions appState) (M.insert (T.pack token) (userId user))
                addHeader "Set-Cookie" (TL.pack $ "session_id=" ++ token ++ "; Path=/; HttpOnly")
                jsonWithStatus 200 $ object ["id" .= userId user, "username" .= username user]
              else
                jsonError 401 "Invalid credentials"

    post "/logout" $ do
      _ <- requireAuth appState
      mToken <- getCookieValue "session_id"
      case mToken of
        Just token -> liftIO $ atomically $ modifyTVar (stateSessions appState) (M.delete token)
        Nothing -> return ()
      jsonWithStatus 200 (object [])

    get "/me" $ do
      uid <- requireAuth appState
      usersById <- liftIO $ readTVarIO (stateUsersById appState)
      case IM.lookup uid usersById of
        Nothing -> jsonError 500 "User not found"
        Just user -> jsonWithStatus 200 $ object ["id" .= userId user, "username" .= username user]

    put "/password" $ do
      uid <- requireAuth appState
      bodyData <- body
      case eitherDecode bodyData of
        Left _ -> jsonError 400 "Invalid request"
        Right (PasswordReq oldPass newPass) -> do
          if T.length newPass < 8 then
            jsonError 400 "Password too short"
          else do
            usersById <- liftIO $ readTVarIO (stateUsersById appState)
            case IM.lookup uid usersById of
              Nothing -> jsonError 500 "User not found"
              Just user -> do
                if passwordHash user /= hashPassword (username user) oldPass then
                  jsonError 401 "Invalid credentials"
                else do
                  let newHash = hashPassword (username user) newPass
                      newUser = user { passwordHash = newHash }
                  liftIO $ atomically $ do
                    modifyTVar (stateUsersById appState) (IM.insert uid newUser)
                    modifyTVar (stateUsersByName appState) (M.insert (username user) newUser)
                  jsonWithStatus 200 (object [])

    get "/todos" $ do
      uid <- requireAuth appState
      todosMap <- liftIO $ readTVarIO (stateTodos appState)
      let userTodos = filter (\t -> ownerId t == uid) (IM.elems todosMap)
          sortedTodos = sortBy (comparing todoId) userTodos
      jsonWithStatus 200 (map todoToJSON sortedTodos)

    post "/todos" $ do
      uid <- requireAuth appState
      bodyData <- body
      case eitherDecode bodyData of
        Left _ -> jsonError 400 "Title is required"
        Right (CreateTodoReq t mDesc) -> do
          let d = fromMaybe "" mDesc
          if T.null t then
            jsonError 400 "Title is required"
          else do
            now <- liftIO getCurrentTime
            tid <- liftIO $ atomically $ do
              tid <- readTVar (stateNextTodoId appState)
              writeTVar (stateNextTodoId appState) (tid + 1)
              let newTodo = Todo tid uid t d False now now
              modifyTVar (stateTodos appState) (IM.insert tid newTodo)
              return tid
            
            todosMap <- liftIO $ readTVarIO (stateTodos appState)
            case IM.lookup tid todosMap of
              Nothing -> jsonError 500 "Failed to create todo"
              Just newTodo -> jsonWithStatus 201 (todoToJSON newTodo)

    get "/todos/:id" $ do
      uid <- requireAuth appState
      tidStr <- pathParam "id"
      case readMaybe (T.unpack tidStr) :: Maybe Int of
        Nothing -> jsonError 404 "Todo not found"
        Just tid -> do
          todosMap <- liftIO $ readTVarIO (stateTodos appState)
          case IM.lookup tid todosMap of
            Nothing -> jsonError 404 "Todo not found"
            Just todo -> 
              if ownerId todo /= uid then
                jsonError 404 "Todo not found"
              else
                jsonWithStatus 200 (todoToJSON todo)

    put "/todos/:id" $ do
      uid <- requireAuth appState
      tidStr <- pathParam "id"
      case readMaybe (T.unpack tidStr) :: Maybe Int of
        Nothing -> jsonError 404 "Todo not found"
        Just tid -> do
          bodyData <- body
          let parsed = if LBS.null bodyData 
                       then Right (UpdateTodoReq Nothing Nothing Nothing) 
                       else eitherDecode bodyData :: Either String UpdateTodoReq
          case parsed of
            Left _ -> jsonError 400 "Invalid request"
            Right req -> do
              todosMap <- liftIO $ readTVarIO (stateTodos appState)
              case IM.lookup tid todosMap of
                Nothing -> jsonError 404 "Todo not found"
                Just todo -> 
                  if ownerId todo /= uid then
                    jsonError 404 "Todo not found"
                  else do
                    let newTitle = fromMaybe (title todo) (updTitle req)
                    if T.null newTitle then
                      jsonError 400 "Title is required"
                    else do
                      now <- liftIO getCurrentTime
                      let newDesc = fromMaybe (description todo) (updDescription req)
                          newCompleted = fromMaybe (completed todo) (updCompleted req)
                          updatedTodo = todo 
                            { title = newTitle
                            , description = newDesc
                            , completed = newCompleted
                            , updatedAt = now
                            }
                      liftIO $ atomically $ modifyTVar (stateTodos appState) (IM.insert tid updatedTodo)
                      jsonWithStatus 200 (todoToJSON updatedTodo)

    delete "/todos/:id" $ do
      uid <- requireAuth appState
      tidStr <- pathParam "id"
      case readMaybe (T.unpack tidStr) :: Maybe Int of
        Nothing -> jsonError 404 "Todo not found"
        Just tid -> do
          todosMap <- liftIO $ readTVarIO (stateTodos appState)
          case IM.lookup tid todosMap of
            Nothing -> jsonError 404 "Todo not found"
            Just todo -> 
              if ownerId todo /= uid then
                jsonError 404 "Todo not found"
              else do
                liftIO $ atomically $ modifyTVar (stateTodos appState) (IM.delete tid)
                status (HT.mkStatus 204 "")
                raw ""

data RegisterReq = RegisterReq { regUsername :: Text, regPassword :: Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \v -> RegisterReq
    <$> v .: "username"
    <*> v .: "password"

data LoginReq = LoginReq { logUsername :: Text, logPassword :: Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \v -> LoginReq
    <$> v .: "username"
    <*> v .: "password"

data PasswordReq = PasswordReq { pwdOldPassword :: Text, pwdNewPassword :: Text }
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \v -> PasswordReq
    <$> v .: "old_password"
    <*> v .: "new_password"

data CreateTodoReq = CreateTodoReq { todoTitle :: Text, todoDescription :: Maybe Text }
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \v -> CreateTodoReq
    <$> v .: "title"
    <*> v .:? "description"

data UpdateTodoReq = UpdateTodoReq 
  { updTitle :: Maybe Text
  , updDescription :: Maybe Text
  , updCompleted :: Maybe Bool
  }
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \v -> UpdateTodoReq
    <$> v .:? "title"
    <*> v .:? "description"
    <*> v .:? "completed"

getPortArg :: IO Int
getPortArg = do
  args <- getArgs
  let port = case args of
        ["--port", p] -> read p
        _ -> 8080
  return port
