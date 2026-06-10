{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Main where

import Control.Concurrent.MVar
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
import Data.Aeson.Types
import Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Clock
import Data.Time.Format
import Web.Scotty
import Network.HTTP.Types (Status, status200, status201, status204, status400, status401, status404, status409)
import Network.Wai (Request, lazyRequestBody, pathInfo, requestHeaders)
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import GHC.Generics
import Text.Read (readMaybe)
import System.Environment (getArgs)
import Data.Maybe (fromMaybe)
import Data.List (sortOn, find)
import Data.CaseInsensitive (mk)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB

data User = User
  { uId :: Int
  , uUsername :: Text
  , uPassword :: Text
  } deriving (Show, Generic)

instance ToJSON User where
  toJSON (User i u _) = object ["id" .= i, "username" .= u]

data UserResponse = UserResponse
  { urId :: Int
  , urUsername :: Text
  } deriving (Show, Generic)

instance ToJSON UserResponse where
  toJSON (UserResponse i u) = object ["id" .= i, "username" .= u]

data Todo = Todo
  { tId :: Int
  , tUserId :: Int
  , tTitle :: Text
  , tDescription :: Text
  , tCompleted :: Bool
  , tCreatedAt :: Text
  , tUpdatedAt :: Text
  } deriving (Show, Generic)

instance ToJSON Todo where
  toJSON (Todo i uid title desc comp created updated) =
    object [ "id" .= i
           , "title" .= title
           , "description" .= desc
           , "completed" .= comp
           , "created_at" .= created
           , "updated_at" .= updated
           ]

data AppState = AppState
  { asNextUserId :: Int
  , asUsers :: Map Int User
  , asUsernameToId :: Map Text Int
  , asNextTodoId :: Int
  , asTodos :: Map Int Todo
  , asSessions :: Map Text Int
  } deriving (Show)

initState :: AppState
initState = AppState 1 Map.empty Map.empty 1 Map.empty Map.empty

isValidUsername :: Text -> Bool
isValidUsername u =
  let len = T.length u
      isValidChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
  in len >= 3 && len <= 50 && T.all isValidChar u

generateSessionToken :: IO Text
generateSessionToken = do
  uuid <- nextRandom
  return $ pack $ toString uuid

jsonError :: Status -> Text -> ActionM ()
jsonError st msg = do
  status st
  json (object ["error" .= msg])

requireJson :: FromJSON a => ActionM (Either Text a)
requireJson = do
  req <- request
  body <- liftIO $ lazyRequestBody req
  case eitherDecode body of
    Left _ -> return $ Left "Invalid request"
    Right val -> return $ Right val

getCookieVal :: Text -> Request -> Maybe Text
getCookieVal name req = do
  let headers = requestHeaders req
  cookieHeader <- lookup (mk "Cookie") headers
  let cookies = B.split ';' cookieHeader
  let prefix = encodeUtf8 name <> "="
  let target = find (B.isPrefixOf prefix . B.dropWhile (== ' ')) cookies
  case target of
    Just c -> Just $ decodeUtf8 $ B.drop (B.length prefix) (B.dropWhile (== ' ') c)
    Nothing -> Nothing

maybeAuth :: MVar AppState -> ActionM (Maybe Int)
maybeAuth stateVar = do
  req <- request
  let token = getCookieVal "session_id" req
  mvar <- liftIO $ readMVar stateVar
  return $ token >>= \t -> Map.lookup t (asSessions mvar)

data RegisterReq = RegisterReq { reqUsername :: Maybe Text, reqPassword :: Maybe Text }
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \v -> RegisterReq
    <$> v .:? "username"
    <*> v .:? "password"

data LoginReq = LoginReq { loginUsername :: Maybe Text, loginPassword :: Maybe Text }
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \v -> LoginReq
    <$> v .:? "username"
    <*> v .:? "password"

data PasswordReq = PasswordReq { reqOldPassword :: Maybe Text, reqNewPassword :: Maybe Text }
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \v -> PasswordReq
    <$> v .:? "old_password"
    <*> v .:? "new_password"

data CreateTodoReq = CreateTodoReq { reqTitle :: Maybe Text, reqDescription :: Maybe Text }
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \v -> CreateTodoReq
    <$> v .:? "title"
    <*> v .:? "description"

data UpdateTodoReq = UpdateTodoReq
  { reqTitleM :: Maybe Text
  , reqDescriptionM :: Maybe Text
  , reqCompletedM :: Maybe Bool
  }
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \v -> UpdateTodoReq
    <$> v .:? "title"
    <*> v .:? "description"
    <*> v .:? "completed"

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
               ["--port", p] -> read p
               _ -> 8080
  stateVar <- newMVar initState
  scotty port $ do
    post "/register" $ do
      res <- requireJson :: ActionM (Either Text RegisterReq)
      case res of
        Left _ -> jsonError status400 "Invalid request"
        Right req -> do
          let mbUser = reqUsername req
          let mbPass = reqPassword req
          if mbUser == Nothing || mbPass == Nothing
            then jsonError status400 "Invalid request"
            else do
              let uname = fromMaybe "" mbUser
              let pwd = fromMaybe "" mbPass
              if not (isValidUsername uname)
                then jsonError status400 "Invalid username"
                else if T.length pwd < 8
                  then jsonError status400 "Password too short"
                  else do
                    mvar <- liftIO $ readMVar stateVar
                    let existing = Map.lookup uname (asUsernameToId mvar)
                    case existing of
                      Just _ -> jsonError status409 "Username already exists"
                      Nothing -> do
                        let newId = asNextUserId mvar
                            newUser = User newId uname pwd
                            newState = mvar
                              { asNextUserId = newId + 1
                              , asUsers = Map.insert newId newUser (asUsers mvar)
                              , asUsernameToId = Map.insert uname newId (asUsernameToId mvar)
                              }
                        liftIO $ swapMVar stateVar newState
                        status status201
                        json (UserResponse newId uname)

    post "/login" $ do
      res <- requireJson :: ActionM (Either Text LoginReq)
      case res of
        Left _ -> jsonError status400 "Invalid request"
        Right req -> do
          let mbUser = loginUsername req
          let mbPass = loginPassword req
          if mbUser == Nothing || mbPass == Nothing
            then jsonError status400 "Invalid request"
            else do
              let uname = fromMaybe "" mbUser
              let pwd = fromMaybe "" mbPass
              mvar <- liftIO $ readMVar stateVar
              case Map.lookup uname (asUsernameToId mvar) of
                Just uid ->
                  case Map.lookup uid (asUsers mvar) of
                    Just u | pwd == uPassword u -> do
                      token <- liftIO generateSessionToken
                      let newState = mvar { asSessions = Map.insert token uid (asSessions mvar) }
                      liftIO $ swapMVar stateVar newState
                      setHeader "Set-Cookie" (LT.pack $ "session_id=" ++ unpack token ++ "; Path=/; HttpOnly")
                      json (UserResponse uid uname)
                    _ -> jsonError status401 "Invalid credentials"
                Nothing -> jsonError status401 "Invalid credentials"

    post "/logout" $ do
      req <- request
      let token = getCookieVal "session_id" req
      mvar <- liftIO $ readMVar stateVar
      case token >>= \t -> Map.lookup t (asSessions mvar) of
        Just _uid -> do
          let newSessions = case token of
                Just t -> Map.delete t (asSessions mvar)
                Nothing -> asSessions mvar
          let newState = mvar { asSessions = newSessions }
          liftIO $ swapMVar stateVar newState
          status status200
          json (object [] :: Value)
        Nothing -> jsonError status401 "Authentication required"

    get "/me" $ do
      muid <- maybeAuth stateVar
      case muid of
        Just uid -> do
          mvar <- liftIO $ readMVar stateVar
          case Map.lookup uid (asUsers mvar) of
            Just u -> json (UserResponse (uId u) (uUsername u))
            Nothing -> jsonError status401 "Authentication required"
        Nothing -> jsonError status401 "Authentication required"

    put "/password" $ do
      muid <- maybeAuth stateVar
      case muid of
        Just uid -> do
          res <- requireJson :: ActionM (Either Text PasswordReq)
          case res of
            Left _ -> jsonError status400 "Invalid request"
            Right req -> do
              let mbOld = reqOldPassword req
              let mbNew = reqNewPassword req
              if mbOld == Nothing || mbNew == Nothing
                then jsonError status400 "Invalid request"
                else do
                  let oldPass = fromMaybe "" mbOld
                  let newPass = fromMaybe "" mbNew
                  mvar <- liftIO $ readMVar stateVar
                  case Map.lookup uid (asUsers mvar) of
                    Just u | oldPass == uPassword u ->
                      if T.length newPass < 8
                        then jsonError status400 "Password too short"
                        else do
                          let newUser = u { uPassword = newPass }
                          let newState = mvar { asUsers = Map.insert uid newUser (asUsers mvar) }
                          liftIO $ swapMVar stateVar newState
                          status status200
                          json (object [] :: Value)
                    Just _ -> jsonError status401 "Invalid credentials"
                    Nothing -> jsonError status401 "Authentication required"
        Nothing -> jsonError status401 "Authentication required"

    get "/todos" $ do
      muid <- maybeAuth stateVar
      case muid of
        Just uid -> do
          mvar <- liftIO $ readMVar stateVar
          let userTodos = Map.elems $ Map.filter (\t -> tUserId t == uid) (asTodos mvar)
              sortedTodos = sortOn tId userTodos
          json sortedTodos
        Nothing -> jsonError status401 "Authentication required"

    post "/todos" $ do
      muid <- maybeAuth stateVar
      case muid of
        Just uid -> do
          res <- requireJson :: ActionM (Either Text CreateTodoReq)
          case res of
            Left _ -> jsonError status400 "Invalid request"
            Right req -> do
              let titleMb = reqTitle req
              case titleMb of
                Just ttitle | not (T.null ttitle) -> do
                  mvar <- liftIO $ readMVar stateVar
                  now <- liftIO getCurrentTime
                  let timeStr = pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
                      newId = asNextTodoId mvar
                      desc = fromMaybe "" (reqDescription req)
                      newTodo = Todo newId uid ttitle desc False timeStr timeStr
                      newState = mvar
                        { asNextTodoId = newId + 1
                        , asTodos = Map.insert newId newTodo (asTodos mvar)
                        }
                  liftIO $ swapMVar stateVar newState
                  status status201
                  json newTodo
                _ -> jsonError status400 "Title is required"
        Nothing -> jsonError status401 "Authentication required"

    get "/todos/:id" $ do
      req <- request
      muid <- maybeAuth stateVar
      case muid of
        Just uid -> do
          let pathParts = pathInfo req
              tidStr = if length pathParts >= 2 then pathParts !! 1 else ""
          case readMaybe (unpack tidStr) :: Maybe Int of
            Just tid -> do
              mvar <- liftIO $ readMVar stateVar
              case Map.lookup tid (asTodos mvar) of
                Just t | tUserId t == uid -> json t
                Just _ -> jsonError status404 "Todo not found"
                Nothing -> jsonError status404 "Todo not found"
            Nothing -> jsonError status404 "Todo not found"
        Nothing -> jsonError status401 "Authentication required"

    put "/todos/:id" $ do
      req <- request
      muid <- maybeAuth stateVar
      case muid of
        Just uid -> do
          let pathParts = pathInfo req
              tidStr = if length pathParts >= 2 then pathParts !! 1 else ""
          case readMaybe (unpack tidStr) :: Maybe Int of
            Just tid -> do
              res <- requireJson :: ActionM (Either Text UpdateTodoReq)
              case res of
                Left _ -> jsonError status400 "Invalid request"
                Right req -> do
                  mvar <- liftIO $ readMVar stateVar
                  case Map.lookup tid (asTodos mvar) of
                    Just t | tUserId t == uid -> do
                      let hasEmptyTitle = case reqTitleM req of
                            Just "" -> True
                            _ -> False
                      if hasEmptyTitle
                        then jsonError status400 "Title is required"
                        else do
                          now <- liftIO getCurrentTime
                          let timeStr = pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
                              finalTitle = fromMaybe (tTitle t) (reqTitleM req)
                              finalDesc = fromMaybe (tDescription t) (reqDescriptionM req)
                              finalCompleted = fromMaybe (tCompleted t) (reqCompletedM req)
                              updatedTodo = t
                                { tTitle = finalTitle
                                , tDescription = finalDesc
                                , tCompleted = finalCompleted
                                , tUpdatedAt = timeStr
                                }
                          let newState = mvar { asTodos = Map.insert tid updatedTodo (asTodos mvar) }
                          liftIO $ swapMVar stateVar newState
                          status status200
                          json updatedTodo
                    Just _ -> jsonError status404 "Todo not found"
                    Nothing -> jsonError status404 "Todo not found"
            Nothing -> jsonError status404 "Todo not found"
        Nothing -> jsonError status401 "Authentication required"

    delete "/todos/:id" $ do
      req <- request
      muid <- maybeAuth stateVar
      case muid of
        Just uid -> do
          let pathParts = pathInfo req
              tidStr = if length pathParts >= 2 then pathParts !! 1 else ""
          case readMaybe (unpack tidStr) :: Maybe Int of
            Just tid -> do
              mvar <- liftIO $ readMVar stateVar
              case Map.lookup tid (asTodos mvar) of
                Just t | tUserId t == uid -> do
                  let newState = mvar { asTodos = Map.delete tid (asTodos mvar) }
                  liftIO $ swapMVar stateVar newState
                  status status204
                Just _ -> jsonError status404 "Todo not found"
                Nothing -> jsonError status404 "Todo not found"
            Nothing -> jsonError status404 "Todo not found"
        Nothing -> jsonError status401 "Authentication required"
