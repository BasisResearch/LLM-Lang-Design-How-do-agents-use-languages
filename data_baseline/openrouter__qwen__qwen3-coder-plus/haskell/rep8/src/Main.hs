{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.UUID.V4 as UUID4
import qualified Data.UUID as UUID
import qualified Web.Scotty.Internal.Types as Scotty
import Web.Scotty 
import Network.HTTP.Types hiding (delete)
import qualified Network.HTTP.Types.Header as H
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import Data.Time
import Control.Monad.IO.Class (liftIO)
import Data.List (find)  
import System.Environment(getArgs)
import Control.Concurrent(MVar, newMVar, readMVar, putMVar)
import Text.Read (readMaybe)
import Control.Monad (join)

-- Data Types
data User = User 
  { userId :: Int
  , username :: String
  , userPassword :: String  
  } deriving (Show, Eq)

instance ToJSON User where
  toJSON (User uid uname _) = object [ "id" .= uid, "username" .= T.pack uname ]

data Todo = Todo 
  { todoId :: Int
  , todoOwnerId :: Int
  , title :: String
  , description :: String
  , completed :: Bool
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON (Todo tid _ t d c ct ut) = object [
      "id" .= tid,
      "title" .= T.pack t,
      "description" .= T.pack d,
      "completed" .= c,
      "created_at" .= formatUTC ct,
      "updated_at" .= formatUTC ut
    ]

data AppState = AppState
  { users :: Map.Map Int User
  , todos :: Map.Map Int Todo
  , sessions :: Map.Map String Int  -- sessionId -> userId
  , nextUserId :: Int  
  , nextTodoId :: Int
  } deriving (Show)

-- Helper Functions
formatUTC :: UTCTime -> T.Text
formatUTC = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

createSessionId :: IO String
createSessionId = do
  uuid <- UUID4.nextRandom
  return $ map toLower $ UUID.toString uuid
  where
    toLower c | c >= 'A' && c <= 'Z' = toEnum $ fromEnum c - fromEnum 'A' + fromEnum 'a'
              | otherwise = c

-- State management functions
initialState :: AppState
initialState = AppState
  { users = Map.empty
  , todos = Map.empty
  , sessions = Map.empty  
  , nextUserId = 1
  , nextTodoId = 1
  }

emptyErrorMessage :: T.Text -> Value
emptyErrorMessage msg = object [ "error" .= msg ]

getUserBySession :: String -> AppState -> Maybe User
getUserBySession sessionId appState = 
  case Map.lookup sessionId (sessions appState) of
    Nothing -> Nothing
    Just userId -> Map.lookup userId (users appState)

-- Validation functions
isValidUsername :: String -> Bool
isValidUsername s = length s >= 3 && length s <= 50 && all isValidChar s
  where
    isValidChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || 
                    (c >= '0' && c <= '9') || c == '_'

isPasswordValid :: String -> Bool
isPasswordValid s = length s >= 8

getStringValue :: Value -> T.Text -> Maybe T.Text
getStringValue (Object o) key = case KM.lookup (Key.fromText key) o of
                                  Just (String s) -> Just s
                                  _ -> Nothing
getStringValue _ _ = Nothing

getBoolValue :: Value -> T.Text -> Maybe Bool
getBoolValue (Object o) key = case KM.lookup (Key.fromText key) o of
                                Just (Bool b) -> Just b
                                _ -> Nothing
getBoolValue _ _ = Nothing

-- Helper functions
mySplit :: Char -> String -> [String]
mySplit delimiter str = go str []
  where
    go s acc = 
      case break (== delimiter) s of
        (chunk, []) -> reverse $ chunk : acc
        (chunk, _:rest) -> go rest $ chunk : acc

-- Updated to work with Lazy Text
parseSessionId :: TL.Text -> Maybe String
parseSessionId cookieTxt = 
  let cookieStr = TL.unpack cookieTxt
      pairs = map (span (/= '=')) $ mySplit ';' cookieStr
      maybeSessionValue = lookup "session_id" $ map (\(k,v) -> let cleanK = dropWhile (== ' ') k in (cleanK, dropWhile (== ' ') $ drop 1 v)) pairs
  in maybeSessionValue

-- Main application
main :: IO ()
main = do
  args <- getArgs
  let port = getPort args
  
  -- Initialize the state
  appRef <- newMVar initialState
  
  scotty port $ do
    -- Helper to get auth user
    let requireAuth action = do
          mCookieVal <- header "Cookie"
          let mSessionId = case mCookieVal of
                             Just cookieLazyTxt -> parseSessionId cookieLazyTxt
                             Nothing -> Nothing
          case mSessionId of
            Nothing -> do
              status status401
              json $ emptyErrorMessage "Authentication required"
            Just sessionId -> do
              state <- liftIO $ readMVar appRef
              let mAuthUser = getUserBySession sessionId state
              case mAuthUser of
                Nothing -> do
                  status status401
                  json $ emptyErrorMessage "Authentication required"
                Just user -> action user sessionId
    
    -- Register endpoint
    post "/register" $ do
      reqData <- jsonData :: ActionM Value
      let mUsername = getStringValue reqData "username"
          mPassword = getStringValue reqData "password"
          
      case (mUsername, mPassword) of
        (Just u, Just p) -> do
          let uname = T.unpack u
              pass = T.unpack p
          
          if not (isValidUsername uname) then
            do
              status status400
              json $ emptyErrorMessage "Invalid username"
            else if not (isPasswordValid pass) then
              do
                status status400
                json $ emptyErrorMessage "Password too short"
              else do
                state <- liftIO $ readMVar appRef
                let existingUser = find ((== uname) . username) (map snd $ Map.toList $ users state)
                
                case existingUser of
                  Just _ -> do
                    status status409
                    json $ emptyErrorMessage "Username already exists"
                  Nothing -> do
                    let userToInsert = User (nextUserId state) uname pass
                    let newState = state {
                          nextUserId = nextUserId state + 1,
                          users = Map.insert (nextUserId state) userToInsert (users state)
                       }
                    liftIO $ putMVar appRef newState
                    status status201
                    json userToInsert
        
        _ -> do
          status status400
          json $ emptyErrorMessage "Username and password are required"
    
    -- Login endpoint
    post "/login" $ do
      reqData <- jsonData :: ActionM Value
      let mUsername = getStringValue reqData "username"
          mPassword = getStringValue reqData "password"
          
      case (mUsername, mPassword) of
        (Just u, Just p) -> do
          let uname = T.unpack u
              pass = T.unpack p
          
          state <- liftIO $ readMVar appRef
          let possibleUser = find (\u' -> username u' == uname && userPassword u' == pass) 
                               (map snd $ Map.toList $ users state)
          
          case possibleUser of
            Nothing -> do
              status status401
              json $ emptyErrorMessage "Invalid credentials"
            Just user -> do
              sessionId <- liftIO createSessionId
              let newState = state {
                    sessions = Map.insert sessionId (userId user) (sessions state)
                   }
              liftIO $ putMVar appRef newState
              
              setHeader "Set-Cookie" $ TL.pack $ "session_id=" ++ sessionId ++ "; Path=/; HttpOnly"
              status status200
              json user
          
        _ -> do
          status status400
          json $ emptyErrorMessage "Username and password are required"
    
    -- Logout endpoint  
    post "/logout" $ requireAuth $ \_ sessionId -> do
      state <- liftIO $ readMVar appRef
      let newState = state {
            sessions = Map.delete sessionId (sessions state)
           }
      liftIO $ putMVar appRef newState
      
      setHeader "Set-Cookie" $ TL.pack $ "session_id=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly"
      status status200
      json $ object []
    
    -- Get user info
    get "/me" $ requireAuth $ \user _ -> json user
    
    -- Change password
    put "/password" $ requireAuth $ \user sessionId -> do
      reqData <- jsonData :: ActionM Value
      let mOldPass = getStringValue reqData "old_password"
          mNewPass = getStringValue reqData "new_password"
          
      case (mOldPass, mNewPass) of
        (Just oldP, Just newP) -> do
          let oldPass = T.unpack oldP
              newPass = T.unpack newP
          
          if oldPass /= userPassword user
            then do
              status status401
              json $ emptyErrorMessage "Invalid credentials"
            else if not (isPasswordValid newPass)
              then do
                status status400
                json $ emptyErrorMessage "Password too short"
              else do
                state <- liftIO $ readMVar appRef
                let updatedUser = user { userPassword = newPass }
                    newState = state {
                      users = Map.insert (userId user) updatedUser (users state)
                     }
                liftIO $ putMVar appRef newState
                status status200
                json $ object []
        
        _ -> do
          status status400
          json $ emptyErrorMessage "Old password and new password are required"
    
    -- Get user's todos
    get "/todos" $ requireAuth $ \user _ -> do
      state <- liftIO $ readMVar appRef
      let userTodos = [todo | todo <- map snd $ Map.toList $ todos state, todoOwnerId todo == userId user]
      json userTodos
    
    -- Create todo
    post "/todos" $ requireAuth $ \user _ -> do
      reqData <- jsonData :: ActionM Value
      let mTitle = getStringValue reqData "title"
          mDesc = getStringValue reqData "description"
          
      let titleStr = case mTitle of
                      Nothing -> ""
                      Just t -> T.unpack t
          
      let maybeDesc = getStringValue reqData "description"
          descStr = case maybeDesc of
                      Just d -> T.unpack d
                      Nothing -> ""
          
      if null titleStr
        then do
          status status400
          json $ emptyErrorMessage "Title is required"
        else do
          now <- liftIO getCurrentTime
          state <- liftIO $ readMVar appRef
          let newTodo = Todo 
                { todoId = nextTodoId state
                , todoOwnerId = userId user
                , title = titleStr
                , description = descStr
                , completed = False
                , createdAt = now
                , updatedAt = now
                }
              newState = state {
                nextTodoId = nextTodoId state + 1,
                todos = Map.insert (nextTodoId state) newTodo (todos state)
               }
          liftIO $ putMVar appRef newState
          status status201
          json newTodo
    
    -- Get specific todo
    get "/todos/:id" $ do
       idStr <- captureParam "id"
       mCookieVal <- header "Cookie"
       let mSessionId = case mCookieVal of
                          Just cookieLazyTxt -> parseSessionId cookieLazyTxt
                          Nothing -> Nothing
       case mSessionId of
         Nothing -> do
           status status401
           json $ emptyErrorMessage "Authentication required"
         Just sessionId -> do
           state <- liftIO $ readMVar appRef
           let mAuthUser = getUserBySession sessionId state
           case mAuthUser of
             Nothing -> do
               status status401
               json $ emptyErrorMessage "Authentication required"
             Just user -> 
               case readMaybe idStr of
                 Nothing -> do
                   status status400
                   json $ emptyErrorMessage "Invalid ID"
                 Just todoIdParam -> do
                   state <- liftIO $ readMVar appRef
                   case Map.lookup todoIdParam (todos state) of
                     Nothing -> do
                       status status404
                       json $ emptyErrorMessage "Todo not found"
                     Just todo -> 
                       if todoOwnerId todo /= userId user
                         then do
                           status status404
                           json $ emptyErrorMessage "Todo not found"
                         else json todo
    
    -- Update todo
    put "/todos/:id" $ do
       idStr <- captureParam "id"
       reqData <- jsonData :: ActionM Value
       mCookieVal <- header "Cookie"
       let mSessionId = case mCookieVal of
                          Just cookieLazyTxt -> parseSessionId cookieLazyTxt
                          Nothing -> Nothing
       case mSessionId of
         Nothing -> do
           status status401
           json $ emptyErrorMessage "Authentication required"
         Just sessionId -> do
           state <- liftIO $ readMVar appRef
           let mAuthUser = getUserBySession sessionId state
           case mAuthUser of
             Nothing -> do
               status status401
               json $ emptyErrorMessage "Authentication required"
             Just user -> 
               case readMaybe idStr of
                 Nothing -> do
                   status status400
                   json $ emptyErrorMessage "Invalid ID"
                 Just todoIdParam -> do
                   state <- liftIO $ readMVar appRef
                   case Map.lookup todoIdParam (todos state) of
                     Nothing -> do
                       status status404
                       json $ emptyErrorMessage "Todo not found"
                     Just todo -> 
                       if todoOwnerId todo /= userId user
                         then do
                           status status404
                           json $ emptyErrorMessage "Todo not found"
                         else do
                           -- Extract optional updates
                           let mTitleOpt = getStringValue reqData "title"
                               mDescOpt = getStringValue reqData "description"
                               mCompletedOpt = getBoolValue reqData "completed"
                               
                           -- Check if title is being updated to empty
                           case mTitleOpt of
                             Just t | T.null t -> do
                               status status400
                               json $ emptyErrorMessage "Title is required"
                             _ -> do
                               currentTime <- liftIO getCurrentTime
                               let updatedTodo = todo {
                                     title = case mTitleOpt of 
                                               Just t -> T.unpack t
                                               Nothing -> title todo,
                                     description = case mDescOpt of 
                                                     Just d -> T.unpack d
                                                     Nothing -> description todo,
                                     completed = case mCompletedOpt of
                                                   Just b -> b
                                                   Nothing -> completed todo,
                                     updatedAt = currentTime
                                   }
                               
                               let newState = state {
                                     todos = Map.insert todoIdParam updatedTodo (todos state)
                                    }
                               liftIO $ putMVar appRef newState
                               
                               status status200
                               json updatedTodo
                       
    -- Delete todo
    delete "/todos/:id" $ do
       idStr <- captureParam "id"
       mCookieVal <- header "Cookie"
       let mSessionId = case mCookieVal of
                          Just cookieLazyTxt -> parseSessionId cookieLazyTxt
                          Nothing -> Nothing
       case mSessionId of
         Nothing -> do
           status status401
           json $ emptyErrorMessage "Authentication required"
         Just sessionId -> do
           state <- liftIO $ readMVar appRef
           let mAuthUser = getUserBySession sessionId state
           case mAuthUser of
             Nothing -> do
               status status401
               json $ emptyErrorMessage "Authentication required"
             Just user -> 
               case readMaybe idStr of
                 Nothing -> do
                   status status400
                   json $ emptyErrorMessage "Invalid ID"
                 Just todoIdParam -> do
                   state <- liftIO $ readMVar appRef
                   case Map.lookup todoIdParam (todos state) of
                     Nothing -> do
                       status status404
                       json $ emptyErrorMessage "Todo not found"
                     Just todo -> 
                       if todoOwnerId todo /= userId user
                         then do
                           status status404
                           json $ emptyErrorMessage "Todo not found"
                         else do
                           let newState = state {
                                 todos = Map.delete todoIdParam (todos state)
                                }
                           liftIO $ putMVar appRef newState
                           status status204 -- No content
  where
    getPort [] = 3000  -- Default port
    getPort ("--port":p:_) = case readMaybe p of
                             Just portNum -> portNum
                             Nothing -> error "Invalid port number"
    getPort _ = error "Usage: todo-app --port PORT"