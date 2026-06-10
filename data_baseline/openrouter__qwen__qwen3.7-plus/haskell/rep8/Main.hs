{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO, atomically, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON, Value, object, (.=), (.:?), withObject, parseJSON, eitherDecode)
import qualified Data.Aeson as Aeson
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Function (on)
import qualified Data.List as L
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Time (getCurrentTime, formatTime, defaultTimeLocale)
import Network.HTTP.Types (status200, status201, status204, status400, status401, status404, status409, status500)
import Network.Wai (rawPathInfo)
import System.Environment (getArgs)
import System.Random (randomIO)
import Text.Read (readMaybe)
import Web.Scotty (request, get, post, put, delete, scotty, ActionM, json, status, finish, body, getCookie, setHeader)

data User = User
  { userId :: Int
  , username :: Text
  , password :: Text
  } deriving (Show)

data Todo = Todo
  { todoId :: Int
  , todoUserId :: Int
  , todoTitle :: Text
  , todoDescription :: Text
  , todoCompleted :: Bool
  , todoCreatedAt :: Text
  , todoUpdatedAt :: Text
  } deriving (Show)

data AppState = AppState
  { nextUserId :: Int
  , users :: M.Map Int User
  , usernameToId :: M.Map Text Int
  , nextTodoId :: Int
  , todos :: M.Map Int Todo
  , sessions :: M.Map Text Int
  } deriving (Show)

initialState :: AppState
initialState = AppState
  { nextUserId = 1
  , users = M.empty
  , usernameToId = M.empty
  , nextTodoId = 1
  , todos = M.empty
  , sessions = M.empty
  }

instance ToJSON User where
  toJSON u = object
    [ "id" .= userId u
    , "username" .= username u
    ]

instance ToJSON Todo where
  toJSON t = object
    [ "id" .= todoId t
    , "title" .= todoTitle t
    , "description" .= todoDescription t
    , "completed" .= todoCompleted t
    , "created_at" .= todoCreatedAt t
    , "updated_at" .= todoUpdatedAt t
    ]

data RegisterReq = RegisterReq { regUsername :: Maybe Text, regPassword :: Maybe Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \v -> RegisterReq
    <$> v .:? "username"
    <*> v .:? "password"

data LoginReq = LoginReq { loginUsername :: Maybe Text, loginPassword :: Maybe Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \v -> LoginReq
    <$> v .:? "username"
    <*> v .:? "password"

data PasswordReq = PasswordReq { oldPassword :: Maybe Text, newPassword :: Maybe Text }
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \v -> PasswordReq
    <$> v .:? "old_password"
    <*> v .:? "new_password"

data TodoCreateReq = TodoCreateReq { tcTitle :: Maybe Text, tcDescription :: Maybe Text }
instance FromJSON TodoCreateReq where
  parseJSON = withObject "TodoCreateReq" $ \v -> TodoCreateReq
    <$> v .:? "title"
    <*> v .:? "description"

data TodoUpdateReq = TodoUpdateReq
  { tuTitle :: Maybe Text
  , tuDescription :: Maybe Text
  , tuCompleted :: Maybe Bool
  }
instance FromJSON TodoUpdateReq where
  parseJSON = withObject "TodoUpdateReq" $ \v -> TodoUpdateReq
    <$> v .:? "title"
    <*> v .:? "description"
    <*> v .:? "completed"

isValidUsername :: Text -> Bool
isValidUsername t =
  let len = T.length t
      validChars = T.all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c == '_') t
  in len >= 3 && len <= 50 && validChars

generateToken :: IO Text
generateToken = do
  chars <- mapM (\_ -> do
                   i <- randomIO :: IO Int
                   let hexChars = "0123456789abcdef"
                   return $ hexChars !! (i `mod` 16)
                ) [1..32]
  return $ T.pack chars

getCurrentTimeStr :: IO Text
getCurrentTimeStr = do
  now <- getCurrentTime
  return $ T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

jsonData' :: FromJSON a => ActionM a
jsonData' = do
  b <- body
  case eitherDecode b of
    Left _ -> do
      status status400
      json (Aeson.object ["error" .= ("Invalid JSON" :: Text)] :: Aeson.Value)
      finish
    Right val -> return val

requireAuth :: TVar AppState -> ActionM Int
requireAuth stateTVar = do
  mSession <- getCookie "session_id"
  case mSession of
    Nothing -> do
      status status401
      json (Aeson.object ["error" .= ("Authentication required" :: Text)] :: Aeson.Value)
      finish
    Just token -> do
      st <- liftIO $ readTVarIO stateTVar
      case M.lookup token (sessions st) of
        Nothing -> do
          status status401
          json (Aeson.object ["error" .= ("Authentication required" :: Text)] :: Aeson.Value)
          finish
        Just uid -> return uid

getPortArg :: IO Int
getPortArg = do
  args <- getArgs
  case args of
    ["--port", p] -> return (read p)
    _ -> return 3000

getPathParam :: ActionM Text
getPathParam = do
  req <- request
  let path = TE.decodeUtf8 (rawPathInfo req)
      segments = T.split (== '/') path
  return $ if length segments >= 3 then segments !! 2 else ""

main :: IO ()
main = do
  portArg <- getPortArg
  state <- newTVarIO initialState
  scotty portArg $ do
    
    post "/register" $ do
      req <- jsonData' :: ActionM RegisterReq
      let mU = regUsername req
      let mP = regPassword req
      case mU of
        Nothing -> do
          status status400
          json (Aeson.object ["error" .= ("Invalid username" :: Text)] :: Aeson.Value)
        Just u ->
          if not (isValidUsername u)
            then do
              status status400
              json (Aeson.object ["error" .= ("Invalid username" :: Text)] :: Aeson.Value)
            else case mP of
              Nothing -> do
                status status400
                json (Aeson.object ["error" .= ("Password too short" :: Text)] :: Aeson.Value)
              Just p ->
                if T.length p < 8
                  then do
                    status status400
                    json (Aeson.object ["error" .= ("Password too short" :: Text)] :: Aeson.Value)
                  else do
                    st <- liftIO $ readTVarIO state
                    if M.member u (usernameToId st)
                      then do
                        status status409
                        json (Aeson.object ["error" .= ("Username already exists" :: Text)] :: Aeson.Value)
                      else do
                        let newId = nextUserId st
                        let newUser = User newId u p
                        let newState = st
                              { nextUserId = newId + 1
                              , users = M.insert newId newUser (users st)
                              , usernameToId = M.insert u newId (usernameToId st)
                              }
                        liftIO $ atomically $ writeTVar state newState
                        status status201
                        json (Aeson.object ["id" .= newId, "username" .= u] :: Aeson.Value)

    post "/login" $ do
      req <- jsonData' :: ActionM LoginReq
      case (loginUsername req, loginPassword req) of
        (Just u, Just p) -> do
          st <- liftIO $ readTVarIO state
          case M.lookup u (usernameToId st) of
            Nothing -> do
              status status401
              json (Aeson.object ["error" .= ("Invalid credentials" :: Text)] :: Aeson.Value)
            Just uid ->
              case M.lookup uid (users st) of
                Nothing -> do
                  status status401
                  json (Aeson.object ["error" .= ("Invalid credentials" :: Text)] :: Aeson.Value)
                Just user ->
                  if password user == p
                    then do
                      token <- liftIO generateToken
                      let newState = st { sessions = M.insert token uid (sessions st) }
                      liftIO $ atomically $ writeTVar state newState
                      setHeader "Set-Cookie" $ TL.pack $ "session_id=" ++ T.unpack token ++ "; Path=/; HttpOnly"
                      status status200
                      json (Aeson.object ["id" .= userId user, "username" .= username user] :: Aeson.Value)
                    else do
                      status status401
                      json (Aeson.object ["error" .= ("Invalid credentials" :: Text)] :: Aeson.Value)
        _ -> do
          status status401
          json (Aeson.object ["error" .= ("Invalid credentials" :: Text)] :: Aeson.Value)

    post "/logout" $ do
      _ <- requireAuth state
      mSession <- getCookie "session_id"
      case mSession of
        Just token -> do
          st <- liftIO $ readTVarIO state
          let newState = st { sessions = M.delete token (sessions st) }
          liftIO $ atomically $ writeTVar state newState
        Nothing -> return ()
      status status200
      json (Aeson.object [] :: Aeson.Value)

    get "/me" $ do
      uid <- requireAuth state
      st <- liftIO $ readTVarIO state
      case M.lookup uid (users st) of
        Just user -> do
          status status200
          json (Aeson.object ["id" .= userId user, "username" .= username user] :: Aeson.Value)
        Nothing -> do
          status status500
          json (Aeson.object ["error" .= ("Internal error" :: Text)] :: Aeson.Value)

    put "/password" $ do
      uid <- requireAuth state
      req <- jsonData' :: ActionM PasswordReq
      st <- liftIO $ readTVarIO state
      case M.lookup uid (users st) of
        Just user ->
          case (oldPassword req, newPassword req) of
            (Just oldP, Just newP) ->
              if password user /= oldP
                then do
                  status status401
                  json (Aeson.object ["error" .= ("Invalid credentials" :: Text)] :: Aeson.Value)
                else if T.length newP < 8
                  then do
                    status status400
                    json (Aeson.object ["error" .= ("Password too short" :: Text)] :: Aeson.Value)
                  else do
                    let newUser = user { password = newP }
                    let newState = st { users = M.insert uid newUser (users st) }
                    liftIO $ atomically $ writeTVar state newState
                    status status200
                    json (Aeson.object [] :: Aeson.Value)
            (Just _, Nothing) -> do
              status status400
              json (Aeson.object ["error" .= ("Password too short" :: Text)] :: Aeson.Value)
            _ -> do
              status status401
              json (Aeson.object ["error" .= ("Invalid credentials" :: Text)] :: Aeson.Value)
        Nothing -> do
          status status500
          json (Aeson.object ["error" .= ("Internal error" :: Text)] :: Aeson.Value)

    get "/todos" $ do
      uid <- requireAuth state
      st <- liftIO $ readTVarIO state
      let userTodosList = [ t | t <- M.elems (todos st), todoUserId t == uid ]
      let sortedTodos = L.sortBy (compare `on` todoId) userTodosList
      status status200
      json sortedTodos

    post "/todos" $ do
      uid <- requireAuth state
      req <- jsonData' :: ActionM TodoCreateReq
      let mTitle = tcTitle req
      case mTitle of
        Nothing -> do
          status status400
          json (Aeson.object ["error" .= ("Title is required" :: Text)] :: Aeson.Value)
        Just t ->
          if T.null t
            then do
              status status400
              json (Aeson.object ["error" .= ("Title is required" :: Text)] :: Aeson.Value)
            else do
              now <- liftIO getCurrentTimeStr
              st <- liftIO $ readTVarIO state
              let newId = nextTodoId st
              let newTodo = Todo
                    { todoId = newId
                    , todoUserId = uid
                    , todoTitle = t
                    , todoDescription = fromMaybe "" (tcDescription req)
                    , todoCompleted = False
                    , todoCreatedAt = now
                    , todoUpdatedAt = now
                    }
              let newState = st
                    { nextTodoId = newId + 1
                    , todos = M.insert newId newTodo (todos st)
                    }
              liftIO $ atomically $ writeTVar state newState
              status status201
              json newTodo

    get "/todos/:id" $ do
      uid <- requireAuth state
      tidStr <- getPathParam
      case readMaybe (T.unpack tidStr) :: Maybe Int of
        Nothing -> do
          status status404
          json (Aeson.object ["error" .= ("Todo not found" :: Text)] :: Aeson.Value)
        Just tid -> do
          st <- liftIO $ readTVarIO state
          case M.lookup tid (todos st) of
            Just t | todoUserId t == uid -> do
              status status200
              json t
            _ -> do
              status status404
              json (Aeson.object ["error" .= ("Todo not found" :: Text)] :: Aeson.Value)

    put "/todos/:id" $ do
      uid <- requireAuth state
      tidStr <- getPathParam
      req <- jsonData' :: ActionM TodoUpdateReq
      case readMaybe (T.unpack tidStr) :: Maybe Int of
        Nothing -> do
          status status404
          json (Aeson.object ["error" .= ("Todo not found" :: Text)] :: Aeson.Value)
        Just tid -> do
          st <- liftIO $ readTVarIO state
          case M.lookup tid (todos st) of
            Just t | todoUserId t == uid -> do
              let mTitle = tuTitle req
              case mTitle of
                Just newT | T.null newT -> do
                  status status400
                  json (Aeson.object ["error" .= ("Title is required" :: Text)] :: Aeson.Value)
                _ -> do
                  now <- liftIO getCurrentTimeStr
                  let newTitle = fromMaybe (todoTitle t) (tuTitle req)
                  let newDesc = fromMaybe (todoDescription t) (tuDescription req)
                  let newComp = fromMaybe (todoCompleted t) (tuCompleted req)
                  let newTodo = t
                        { todoTitle = newTitle
                        , todoDescription = newDesc
                        , todoCompleted = newComp
                        , todoUpdatedAt = now
                        }
                  let newState = st { todos = M.insert tid newTodo (todos st) }
                  liftIO $ atomically $ writeTVar state newState
                  status status200
                  json newTodo
            _ -> do
              status status404
              json (Aeson.object ["error" .= ("Todo not found" :: Text)] :: Aeson.Value)

    delete "/todos/:id" $ do
      uid <- requireAuth state
      tidStr <- getPathParam
      case readMaybe (T.unpack tidStr) :: Maybe Int of
        Nothing -> do
          status status404
          json (Aeson.object ["error" .= ("Todo not found" :: Text)] :: Aeson.Value)
        Just tid -> do
          st <- liftIO $ readTVarIO state
          case M.lookup tid (todos st) of
            Just t | todoUserId t == uid -> do
              let newState = st { todos = M.delete tid (todos st) }
              liftIO $ atomically $ writeTVar state newState
              status status204
            _ -> do
              status status404
              json (Aeson.object ["error" .= ("Todo not found" :: Text)] :: Aeson.Value)