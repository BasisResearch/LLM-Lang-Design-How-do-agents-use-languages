{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module Main where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Time
import Data.UUID.V4 (nextRandom)
import Data.UUID (toText)
import Web.Scotty
import Network.HTTP.Types (status401, status400, status409, status404, status201, status204, status200, Status)
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Char8 as BS
import Control.Concurrent.STM
import Data.Maybe (isJust, fromMaybe)
import Text.Read (readMaybe)
import GHC.Generics (Generic)
import Data.Char (isAlphaNum, toLower)
import Data.List (sortOn)
import System.Environment (getArgs)
import Network.Wai (requestHeaders, pathInfo)

data User = User
  { userId :: Int
  , userName :: Text
  , userPassword :: Text
  } deriving (Show, Generic)

instance ToJSON User where
  toJSON (User uId uname _) = object ["id" .= uId, "username" .= uname]

data RegisterReq = RegisterReq
  { regUsername :: Text
  , regPassword :: Text
  } deriving (Show, Generic)

instance FromJSON RegisterReq where
  parseJSON = Data.Aeson.genericParseJSON Data.Aeson.defaultOptions { fieldLabelModifier = map toLower . drop 3 }

data LoginReq = LoginReq
  { logUsername :: Text
  , logPassword :: Text
  } deriving (Show, Generic)

instance FromJSON LoginReq where
  parseJSON = Data.Aeson.genericParseJSON Data.Aeson.defaultOptions { fieldLabelModifier = map toLower . drop 3 }

data Todo = Todo
  { todoId :: Int
  , todoUserId :: Int
  , todoTitle :: Text
  , todoDescription :: Text
  , todoCompleted :: Bool
  , todoCreatedAt :: UTCTime
  , todoUpdatedAt :: UTCTime
  } deriving (Show, Generic)

formatTimeISO :: UTCTime -> Text
formatTimeISO t = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t

instance ToJSON Todo where
  toJSON (Todo tId _ title desc comp createdAt updatedAt) =
    object
      [ "id" .= tId
      , "title" .= title
      , "description" .= desc
      , "completed" .= comp
      , "created_at" .= formatTimeISO createdAt
      , "updated_at" .= formatTimeISO updatedAt
      ]

data CreateTodoReq = CreateTodoReq
  { reqTitle :: Maybe Text
  , reqDescription :: Maybe Text
  } deriving (Show, Generic)

instance FromJSON CreateTodoReq where
  parseJSON = Data.Aeson.genericParseJSON Data.Aeson.defaultOptions { fieldLabelModifier = map toLower . drop 3 }

data UpdateTodoReq = UpdateTodoReq
  { updTitle :: Maybe Text
  , updDescription :: Maybe Text
  , updCompleted :: Maybe Bool
  } deriving (Show, Generic)

instance FromJSON UpdateTodoReq where
  parseJSON = Data.Aeson.genericParseJSON Data.Aeson.defaultOptions { fieldLabelModifier = map toLower . drop 3 }

data PasswordChangeReq = PasswordChangeReq
  { reqOldPassword :: Text
  , reqNewPassword :: Text
  } deriving (Show, Generic)

instance FromJSON PasswordChangeReq where
  parseJSON = withObject "PasswordChangeReq" $ \v -> PasswordChangeReq
    <$> v .: "old_password"
    <*> v .: "new_password"

data ErrorResponse = ErrorResponse { error :: Text } deriving (Show, Generic)
instance ToJSON ErrorResponse

data AppState = AppState
  { nextUserId :: TVar Int
  , nextTodoId :: TVar Int
  , users :: TVar (Map Int User)
  , usernameToId :: TVar (Map Text Int)
  , todos :: TVar (Map Int Todo)
  , sessions :: TVar (Map Text Int)
  }

initState :: IO AppState
initState = do
  userIdVar <- newTVarIO 1
  todoIdVar <- newTVarIO 1
  usersVar <- newTVarIO Map.empty
  unameMapVar <- newTVarIO Map.empty
  todosVar <- newTVarIO Map.empty
  sessionsVar <- newTVarIO Map.empty
  return AppState 
    { nextUserId = userIdVar
    , nextTodoId = todoIdVar
    , users = usersVar
    , usernameToId = unameMapVar
    , todos = todosVar
    , sessions = sessionsVar
    }

isValidUsername :: Text -> Bool
isValidUsername u = 
  let s = T.unpack u
      len = length s
  in len >= 3 && len <= 50 && all (\c -> isAlphaNum c || c == '_') s

jsonError :: Status -> Text -> ActionM a
jsonError st errMsg = do
  status st
  json (ErrorResponse errMsg)
  finish

findCookie :: Text -> ActionM (Maybe Text)
findCookie name = do
  req <- request
  let hdrs = requestHeaders req
  case lookup "cookie" hdrs of
    Nothing -> return Nothing
    Just cookieHeader -> 
      let cookies = BS.split ';' cookieHeader
          findVal [] = Nothing
          findVal (c:cs) = 
            let (k, rest) = BS.break (== '=') c
                v = BS.drop 1 rest
                cleanK = BS.dropWhile (== ' ') (BS.reverse (BS.dropWhile (== ' ') (BS.reverse k)))
                cleanV = BS.dropWhile (== ' ') (BS.reverse (BS.dropWhile (== ' ') (BS.reverse v)))
            in if cleanK == TE.encodeUtf8 name 
               then Just (TE.decodeUtf8 cleanV)
               else findVal cs
      in return (findVal cookies)

getPathParam :: ActionM Text
getPathParam = do
  req <- request
  let parts = pathInfo req
  if length parts >= 2
    then return (parts !! 1)
    else return ""

getAuthUser :: AppState -> ActionM (Int, User)
getAuthUser appState = do
  mSession <- findCookie "session_id"
  case mSession of
    Nothing -> jsonError status401 "Authentication required"
    Just sess -> do
      uid <- liftIO $ atomically $ do
        sessionsMap <- readTVar (sessions appState)
        return $ Map.lookup sess sessionsMap
      case uid of
        Nothing -> jsonError status401 "Authentication required"
        Just uid' -> do
          user <- liftIO $ atomically $ do
            usersMap <- readTVar (users appState)
            return $ Map.lookup uid' usersMap
          case user of
            Nothing -> jsonError status401 "Authentication required"
            Just u -> return (uid', u)

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
               ["--port", p] -> read p
               _ -> 3000
  appState <- initState
  scotty port $ do
    post "/register" $ do
      bodyData <- jsonData :: ActionM RegisterReq
      let uname = regUsername bodyData
      let pwd = regPassword bodyData
      
      unless (isValidUsername uname) $ do
        jsonError status400 "Invalid username"
      
      unless (T.length pwd >= 8) $ do
        jsonError status400 "Password too short"
      
      res <- liftIO $ atomically $ do
        usersMap <- readTVar (users appState)
        unameMap <- readTVar (usernameToId appState)
        case Map.lookup uname unameMap of
          Just _ -> return (Left "Username already exists")
          Nothing -> do
            newId <- readTVar (nextUserId appState)
            writeTVar (nextUserId appState) (newId + 1)
            let newUser = User newId uname pwd
            writeTVar (users appState) (Map.insert newId newUser usersMap)
            writeTVar (usernameToId appState) (Map.insert uname newId unameMap)
            return (Right newUser)
            
      case res of
        Left err -> jsonError status409 (T.pack err)
        Right u -> do
          status status201
          json u

    post "/login" $ do
      bodyData <- jsonData :: ActionM LoginReq
      let uname = logUsername bodyData
      let pwd = logPassword bodyData
      
      res <- liftIO $ atomically $ do
        unameMap <- readTVar (usernameToId appState)
        case Map.lookup uname unameMap of
          Nothing -> return Nothing
          Just uid -> do
            usersMap <- readTVar (users appState)
            case Map.lookup uid usersMap of
              Nothing -> return Nothing
              Just u -> if userPassword u == pwd
                        then return (Just u)
                        else return Nothing
      
      case res of
        Nothing -> jsonError status401 "Invalid credentials"
        Just u -> do
          token <- liftIO $ do
            uuid <- nextRandom
            return $ toText uuid
          liftIO $ atomically $ do
            sessMap <- readTVar (sessions appState)
            writeTVar (sessions appState) (Map.insert token (userId u) sessMap)
          
          let cookieVal = TL.pack $ "session_id=" ++ T.unpack token ++ "; Path=/; HttpOnly"
          setHeader "Set-Cookie" cookieVal
          json u

    post "/logout" $ do
      _ <- getAuthUser appState
      mSess <- findCookie "session_id"
      case mSess of
        Nothing -> return ()
        Just sess -> liftIO $ atomically $ do
          sessMap <- readTVar (sessions appState)
          writeTVar (sessions appState) (Map.delete sess sessMap)
      status status200
      json (object [])

    get "/me" $ do
      (_, u) <- getAuthUser appState
      json u

    put "/password" $ do
      (_, u) <- getAuthUser appState
      bodyData <- jsonData :: ActionM PasswordChangeReq
      let oldP = reqOldPassword bodyData
      let newP = reqNewPassword bodyData
      
      when (userPassword u /= oldP) $
        jsonError status401 "Invalid credentials"
        
      when (T.length newP < 8) $
        jsonError status400 "Password too short"
        
      liftIO $ atomically $ do
        usersMap <- readTVar (users appState)
        let updatedU = u { userPassword = newP }
        writeTVar (users appState) (Map.insert (userId u) updatedU usersMap)
        
      status status200
      json (object [])

    get "/todos" $ do
      (uid, _) <- getAuthUser appState
      todosList <- liftIO $ atomically $ do
        todosMap <- readTVar (todos appState)
        let userTodos = Map.filter (\t -> todoUserId t == uid) todosMap
        return $ Map.elems userTodos
      let sortedTodos = sortOn todoId todosList
      json sortedTodos

    post "/todos" $ do
      (uid, _) <- getAuthUser appState
      bodyData <- jsonData :: ActionM CreateTodoReq
      case reqTitle bodyData of
        Nothing -> jsonError status400 "Title is required"
        Just t -> do
          when (T.null t) $
            jsonError status400 "Title is required"
            
          let desc = fromMaybe "" (reqDescription bodyData)
          
          now <- liftIO getCurrentTime
          res <- liftIO $ atomically $ do
            newId <- readTVar (nextTodoId appState)
            writeTVar (nextTodoId appState) (newId + 1)
            let newTodo = Todo newId uid t desc False now now
            todosMap <- readTVar (todos appState)
            writeTVar (todos appState) (Map.insert newId newTodo todosMap)
            return newTodo
            
          status status201
          json res

    get "/todos/:id" $ do
      (uid, _) <- getAuthUser appState
      tidStr <- getPathParam
      let mTid = readMaybe (T.unpack tidStr) :: Maybe Int
      case mTid of
        Nothing -> jsonError status404 "Todo not found"
        Just tid -> do
          res <- liftIO $ atomically $ do
            todosMap <- readTVar (todos appState)
            return $ Map.lookup tid todosMap
          case res of
            Nothing -> jsonError status404 "Todo not found"
            Just todo -> do
              when (todoUserId todo /= uid) $
                jsonError status404 "Todo not found"
              json todo

    put "/todos/:id" $ do
      (uid, _) <- getAuthUser appState
      tidStr <- getPathParam
      let mTid = readMaybe (T.unpack tidStr) :: Maybe Int
      case mTid of
        Nothing -> jsonError status404 "Todo not found"
        Just tid -> do
          bodyData <- jsonData :: ActionM UpdateTodoReq
          when (isJust (updTitle bodyData) && updTitle bodyData == Just "") $
            jsonError status400 "Title is required"
            
          now <- liftIO getCurrentTime
          res <- liftIO $ atomically $ do
            todosMap <- readTVar (todos appState)
            case Map.lookup tid todosMap of
              Nothing -> return (Left ("NotFound" :: String))
              Just todo -> 
                if todoUserId todo /= uid
                  then return (Left ("NotFound" :: String))
                  else do
                    let updatedTodo = todo
                          { todoTitle = fromMaybe (todoTitle todo) (updTitle bodyData)
                          , todoDescription = fromMaybe (todoDescription todo) (updDescription bodyData)
                          , todoCompleted = fromMaybe (todoCompleted todo) (updCompleted bodyData)
                          , todoUpdatedAt = now
                          }
                    writeTVar (todos appState) (Map.insert tid updatedTodo todosMap)
                    return (Right updatedTodo)
                
          case res of
            Left _ -> jsonError status404 "Todo not found"
            Right updatedTodo -> json updatedTodo

    delete "/todos/:id" $ do
      (uid, _) <- getAuthUser appState
      tidStr <- getPathParam
      let mTid = readMaybe (T.unpack tidStr) :: Maybe Int
      case mTid of
        Nothing -> jsonError status404 "Todo not found"
        Just tid -> do
          res <- liftIO $ atomically $ do
            todosMap <- readTVar (todos appState)
            case Map.lookup tid todosMap of
              Nothing -> return (Left ("NotFound" :: String))
              Just todo -> 
                if todoUserId todo /= uid
                  then return (Left ("NotFound" :: String))
                  else do
                    writeTVar (todos appState) (Map.delete tid todosMap)
                    return (Right ())
          case res of
            Left _ -> jsonError status404 "Todo not found"
            Right () -> do
              status status204
