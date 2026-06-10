{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent.STM (TVar, atomically, readTVar, writeTVar, readTVarIO, newTVarIO)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (find, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import qualified Data.Text.Lazy as TL
import Data.Time (UTCTime, getCurrentTime, formatTime, defaultTimeLocale)
import Data.UUID (toString)
import Data.UUID.V4 (nextRandom)
import GHC.Generics (Generic)
import Web.Scotty (scotty, post, get, put, delete, jsonData, request, addHeader, status, json, ActionM)
import Network.HTTP.Types (status400, status401, status404, status409, status200, status201, status204)
import qualified Network.Wai as Wai
import qualified Data.ByteString.Char8 as B8
import qualified Data.Map.Strict as Map
import Data.Aeson
import System.Environment (getArgs)
import Text.Read (readMaybe)

data User = User
  { uId :: Int
  , uUsername :: Text
  , uPassword :: Text
  } deriving (Show, Generic)

instance ToJSON User where
  toJSON (User i u _) = object ["id" .= i, "username" .= u]

data Todo = Todo
  { tId :: Int
  , tUserId :: Int
  , tTitle :: Text
  , tDescription :: Text
  , tCompleted :: Bool
  , tCreatedAt :: UTCTime
  , tUpdatedAt :: UTCTime
  } deriving (Show, Generic)

instance ToJSON Todo where
  toJSON (Todo i _ title desc comp cTime uTime) = object
    [ "id" .= i
    , "title" .= title
    , "description" .= desc
    , "completed" .= comp
    , "created_at" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" cTime
    , "updated_at" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" uTime
    ]

data AppState = AppState
  { nextUserId :: Int
  , nextTodoId :: Int
  , users :: Map.Map Int User
  , userByName :: Map.Map Text Int
  , todos :: Map.Map Int Todo
  , sessions :: Map.Map Text Int
  } deriving (Show)

initialState :: AppState
initialState = AppState
  { nextUserId = 1
  , nextTodoId = 1
  , users = Map.empty
  , userByName = Map.empty
  , todos = Map.empty
  , sessions = Map.empty
  }

isValidUsername :: Text -> Bool
isValidUsername t =
  let len = T.length t
  in len >= 3 && len <= 50 && T.all (\c -> isAsciiUpper c || isAsciiLower c || isDigit c || c == '_') t

isValidPassword :: Text -> Bool
isValidPassword t = T.length t >= 8

data RegisterReq = RegisterReq
  { regUsername :: Text
  , regPassword :: Text
  } deriving (Generic)

instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \v -> RegisterReq
    <$> v .: "username"
    <*> v .: "password"

data LoginReq = LoginReq
  { logUsername :: Text
  , logPassword :: Text
  } deriving (Generic)

instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \v -> LoginReq
    <$> v .: "username"
    <*> v .: "password"

data PasswordReq = PasswordReq
  { reqOldPassword :: Text
  , reqNewPassword :: Text
  } deriving (Generic)

instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \v -> PasswordReq
    <$> v .: "old_password"
    <*> v .: "new_password"

data TodoReq = TodoReq
  { reqTitle :: Text
  , reqDescription :: Maybe Text
  } deriving (Generic)

instance FromJSON TodoReq where
  parseJSON = withObject "TodoReq" $ \v -> TodoReq
    <$> v .: "title"
    <*> v .:? "description"

data UpdateTodoReq = UpdateTodoReq
  { upTitle :: Maybe Text
  , upDescription :: Maybe Text
  , upCompleted :: Maybe Bool
  } deriving (Generic)

instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \v -> UpdateTodoReq
    <$> v .:? "title"
    <*> v .:? "description"
    <*> v .:? "completed"

getSid :: ActionM (Maybe Text)
getSid = do
  req <- request
  let headers = Wai.requestHeaders req
  let mCookie = lookup "cookie" headers
  case mCookie of
    Nothing -> return Nothing
    Just cookieBS -> 
      let cookies = B8.split ';' cookieBS
          match = find (\c -> "session_id=" `B8.isPrefixOf` B8.dropWhile (== ' ') c) cookies
      in case match of
           Nothing -> return Nothing
           Just m -> return (Just (T.pack (B8.unpack (B8.drop 11 (B8.dropWhile (== ' ') m)))))

getPathParam :: ActionM Text
getPathParam = do
  req <- request
  let path = decodeUtf8 (Wai.rawPathInfo req)
  let parts = T.split (== '/') path
  case reverse (filter (not . T.null) parts) of
    (p:_) -> return p
    [] -> return ""

main :: IO ()
main = do
  args <- getArgs
  let portStr = case args of
        ["--port", p] -> p
        _ -> "3000"
  let port = read portStr :: Int
  appStateVar <- newTVarIO initialState
  
  let auth' :: (Int -> Text -> ActionM ()) -> ActionM ()
      auth' action = do
        mSid <- getSid
        case mSid of
          Nothing -> do
            status status401
            json (object ["error" .= ("Authentication required" :: Text)])
          Just sid -> do
            st <- liftIO $ readTVarIO appStateVar
            case Map.lookup sid (sessions st) of
              Nothing -> do
                status status401
                json (object ["error" .= ("Authentication required" :: Text)])
              Just uid -> action uid sid

  scotty port $ do
    post "/register" $ do
      req <- jsonData :: ActionM RegisterReq
      let uname = regUsername req
      let pword = regPassword req
      if not (isValidUsername uname)
        then do
          status status400
          json (object ["error" .= ("Invalid username" :: Text)])
        else if not (isValidPassword pword)
          then do
            status status400
            json (object ["error" .= ("Password too short" :: Text)])
          else do
            res <- liftIO $ atomically $ do
              st <- readTVar appStateVar
              if Map.member uname (userByName st)
                then return (Left ("Username already exists" :: Text))
                else do
                  let uid = nextUserId st
                  let u = User uid uname pword
                  let st' = st
                        { nextUserId = uid + 1
                        , users = Map.insert uid u (users st)
                        , userByName = Map.insert uname uid (userByName st)
                        }
                  writeTVar appStateVar st'
                  return (Right (uid, uname))
            case res of
              Left err -> do
                status status409
                json (object ["error" .= err])
              Right (uid, uname') -> do
                status status201
                json (object ["id" .= uid, "username" .= uname'])

    post "/login" $ do
      req <- jsonData :: ActionM LoginReq
      let uname = logUsername req
      let pword = logPassword req
      res <- liftIO $ atomically $ do
        st <- readTVar appStateVar
        case Map.lookup uname (userByName st) of
          Nothing -> return (Nothing :: Maybe Int)
          Just uid -> case Map.lookup uid (users st) of
            Nothing -> return Nothing
            Just u -> if uPassword u == pword
              then return (Just uid)
              else return Nothing
      case res of
        Nothing -> do
          status status401
          json (object ["error" .= ("Invalid credentials" :: Text)])
        Just uid -> do
          token <- liftIO $ toString <$> nextRandom
          liftIO $ atomically $ do
            st <- readTVar appStateVar
            let st' = st { sessions = Map.insert (T.pack token) uid (sessions st) }
            writeTVar appStateVar st'
          addHeader "Set-Cookie" (TL.pack ("session_id=" ++ token ++ "; Path=/; HttpOnly"))
          status status200
          json (object ["id" .= (uid :: Int), "username" .= uname])

    post "/logout" $ do
      auth' $ \_uid sid -> do
        liftIO $ atomically $ do
          st <- readTVar appStateVar
          let st' = st { sessions = Map.delete sid (sessions st) }
          writeTVar appStateVar st'
        status status200
        json (object [] :: Value)

    get "/me" $ do
      auth' $ \uid _sid -> do
        st <- liftIO $ readTVarIO appStateVar
        case Map.lookup uid (users st) of
          Nothing -> do
            status status401
            json (object ["error" .= ("Authentication required" :: Text)])
          Just u -> do
            status status200
            json (object ["id" .= uId u, "username" .= uUsername u])

    put "/password" $ do
      auth' $ \uid _sid -> do
        req <- jsonData :: ActionM PasswordReq
        let oldP = reqOldPassword req
        let newP = reqNewPassword req
        if not (isValidPassword newP)
          then do
            status status400
            json (object ["error" .= ("Password too short" :: Text)])
          else do
            st <- liftIO $ readTVarIO appStateVar
            case Map.lookup uid (users st) of
              Nothing -> do
                status status401
                json (object ["error" .= ("Invalid credentials" :: Text)])
              Just u -> if uPassword u /= oldP
                then do
                  status status401
                  json (object ["error" .= ("Invalid credentials" :: Text)])
                else do
                  liftIO $ atomically $ do
                    st' <- readTVar appStateVar
                    let u' = u { uPassword = newP }
                    let st'' = st' { users = Map.insert uid u' (users st') }
                    writeTVar appStateVar st''
                  status status200
                  json (object [] :: Value)

    get "/todos" $ do
      auth' $ \uid _sid -> do
        st <- liftIO $ readTVarIO appStateVar
        let userTodos = Map.elems $ Map.filter (\t -> tUserId t == uid) (todos st)
        let sortedTodos = sortOn tId userTodos
        status status200
        json sortedTodos

    post "/todos" $ do
      auth' $ \uid _sid -> do
        req <- jsonData :: ActionM TodoReq
        let t = reqTitle req
        if T.null t
          then do
            status status400
            json (object ["error" .= ("Title is required" :: Text)])
          else do
            let desc = fromMaybe "" (reqDescription req)
            now <- liftIO getCurrentTime
            res <- liftIO $ atomically $ do
              st' <- readTVar appStateVar
              let tid = nextTodoId st'
              let newTodo = Todo tid uid t desc False now now
              let st'' = st'
                    { nextTodoId = tid + 1
                    , todos = Map.insert tid newTodo (todos st')
                    }
              writeTVar appStateVar st''
              return newTodo
            status status201
            json res

    get "/todos/:id" $ do
      auth' $ \uid _sid -> do
        tidTxt <- getPathParam
        case readMaybe (T.unpack tidTxt) of
          Nothing -> do
            status status404
            json (object ["error" .= ("Todo not found" :: Text)])
          Just tid -> do
            st <- liftIO $ readTVarIO appStateVar
            case Map.lookup tid (todos st) of
              Just t | tUserId t == uid -> do
                status status200
                json t
              _ -> do
                status status404
                json (object ["error" .= ("Todo not found" :: Text)])

    put "/todos/:id" $ do
      auth' $ \uid _sid -> do
        tidTxt <- getPathParam
        case readMaybe (T.unpack tidTxt) of
          Nothing -> do
            status status404
            json (object ["error" .= ("Todo not found" :: Text)])
          Just tid -> do
            req <- jsonData :: ActionM UpdateTodoReq
            case upTitle req of
              Just "" -> do
                status status400
                json (object ["error" .= ("Title is required" :: Text)])
              _ -> do
                now <- liftIO getCurrentTime
                res <- liftIO $ atomically $ do
                  st' <- readTVar appStateVar
                  case Map.lookup tid (todos st') of
                    Just t | tUserId t == uid -> do
                      let newTitle = fromMaybe (tTitle t) (upTitle req)
                      let newDesc = fromMaybe (tDescription t) (upDescription req)
                      let newComp = fromMaybe (tCompleted t) (upCompleted req)
                      let newTodo = t { tTitle = newTitle, tDescription = newDesc, tCompleted = newComp, tUpdatedAt = now }
                      let st'' = st' { todos = Map.insert tid newTodo (todos st') }
                      writeTVar appStateVar st''
                      return (Right newTodo :: Either Text Todo)
                    _ -> return (Left "Todo not found")
                case res of
                  Left _ -> do
                    status status404
                    json (object ["error" .= ("Todo not found" :: Text)])
                  Right t -> do
                    status status200
                    json t

    delete "/todos/:id" $ do
      auth' $ \uid _sid -> do
        tidTxt <- getPathParam
        case readMaybe (T.unpack tidTxt) of
          Nothing -> do
            status status404
            json (object ["error" .= ("Todo not found" :: Text)])
          Just tid -> do
            res <- liftIO $ atomically $ do
              st' <- readTVar appStateVar
              case Map.lookup tid (todos st') of
                Just t | tUserId t == uid -> do
                  let st'' = st' { todos = Map.delete tid (todos st') }
                  writeTVar appStateVar st''
                  return (True :: Bool)
                _ -> return False
            if res
              then status status204
              else do
                status status404
                json (object ["error" .= ("Todo not found" :: Text)])