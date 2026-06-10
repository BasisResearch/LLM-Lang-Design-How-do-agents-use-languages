{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Web.Scotty
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as Key
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.ByteString.Char8 as BS
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Time
import Data.List (sortBy, intercalate, find, elemIndex, dropWhileEnd)
import Data.Function (on)
import System.Environment (getArgs)
import Network.HTTP.Types.Status
import Network.Wai.Middleware.RequestLogger
import Network.Wai
import Control.Monad.IO.Class
import qualified Data.Map.Strict as Map
import System.Random (randomRIO)
import Data.UUID.V4 (nextRandom)
import Data.UUID (toString)
import Data.IORef
import Text.Read (readMaybe)
import Control.Monad (unless, void)

-- Define data types
data User = User
  { userId :: Int
  , username :: String
  , password :: String
  } deriving (Show, Eq)

instance ToJSON User where
  toJSON u = object ["id" .= userId u, "username" .= username u]

data Todo = Todo
  { todoId :: Int
  , title :: String
  , description :: String
  , completed :: Bool
  , createdAt :: String
  , updatedAt :: String
  , ownerId :: Int
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON t = object [ "id" .= todoId t
                    , "title" .= title t
                    , "description" .= description t
                    , "completed" .= completed t
                    , "created_at" .= createdAt t
                    , "updated_at" .= updatedAt t
                    ]

data AuthSession = AuthSession
  { sessionValue :: String
  , sessionUserId :: Int
  }

data ServerState = ServerState
  { users :: Map.Map Int User
  , nextUserId :: Int
  , todos :: Map.Map Int Todo
  , nextTodoId :: Int
  , sessions :: Map.Map String AuthSession
  }

emptyState :: ServerState
emptyState = ServerState Map.empty 1 Map.empty 1 Map.empty

-- Utility functions
getCurrentTimeFormatted :: IO String
getCurrentTimeFormatted = do
  now <- getCurrentTime
  return $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

generateSessionId :: IO String
generateSessionId = toString <$> nextRandom

isValidUsername :: String -> Bool
isValidUsername s = length s >= 3 && length s <= 50 &&
  all (\c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') s

-- Parse cookie header to extract session_id, handling both strict and lazy text
getSessionIdFromCookie :: Maybe TL.Text -> Maybe String
getSessionIdFromCookie Nothing = Nothing
getSessionIdFromCookie (Just cookiesHeader) =
  let cookieStr = stripSpaces (TL.unpack cookiesHeader)
      cookiePairs = map (break (== '=')) $ splitOn ';' cookieStr
      cleanedPairs = [(trimComponent $ fst c, trimComponent $ snd c) | c <- cookiePairs]
  in lookup "session_id" cleanedPairs
  where
    trimComponent s = case break (== ';') s of
                    (part, remainder) -> if null part && not (null remainder)
                                         then trimComponent (tail remainder) 
                                         else stripSpaces part
    stripSpaces = dropWhile (== ' ') . dropWhileEnd (== ' ')

splitOn :: Char -> String -> [String]
splitOn c [] = []
splitOn c s = case break (== c) s of
  (pre, c':post) -> pre : splitOn c post
  (pre, _) -> [pre]

-- Safe getter for JSON values
getJSONString :: Value -> T.Text -> Maybe String
getJSONString (Object obj) keyName =
  case KM.lookup (Key.fromText keyName) obj of
    Just (String val) -> Just (T.unpack val)
    _ -> Nothing
getJSONString _ _ = Nothing

getJSONBool :: Value -> T.Text -> Maybe Bool
getJSONBool (Object obj) keyName =
  case KM.lookup (Key.fromText keyName) obj of
    Just (Bool val) -> Just val
    _ -> Nothing
getJSONBool _ _ = Nothing

-- Extract todo ID from path for routes like "/todos/{id}"
getTodoIdFromPath :: ActionM (Maybe Int)
getTodoIdFromPath = do
  waiReq <- request
  let pathStr = BS.unpack $ rawPathInfo waiReq
      pathComponents = filter (not . null) $ splitOn '/' (dropWhile (== '/') pathStr)
  
  case pathComponents of
    ["todos", idStr] -> case readMaybe idStr of
                        Just num -> return (Just num)
                        Nothing -> return Nothing
    _ -> return Nothing

main :: IO ()
main = do
  args <- getArgs
  let portArgIndex = elemIndex "--port" args
  let port = case portArgIndex of
        Nothing -> 3000
        Just idx -> if idx + 1 < length args
                   then fromMaybe 3000 (readMaybe (args !! (idx + 1)))
                   else 3000

  putStrLn $ "Starting server on port " ++ show port ++ "..."
  
  stateRef <- newIORef emptyState

  scotty port $ do
    middleware logStdoutDev

    let modifyState f = liftIO $ modifyIORef stateRef f
        getState = liftIO $ readIORef stateRef

    -- Authentication helper: verifies session and returns user ID
    let authenticateAction action = do
          maybeCookies <- header "Cookie"
          let mSessionId = getSessionIdFromCookie maybeCookies
          state <- getState
          case mSessionId >>= (\sid -> fmap sessionUserId $ Map.lookup sid (sessions state)) of
            Just uid -> action uid
            Nothing -> do
              status unauthorized401
              json $ object ["error" .= ("Authentication required" :: String)]

    -- POST /register
    post "/register" $ do
      reqBody <- jsonData @Value
      let mUsername = getJSONString reqBody "username"
          mPassword = getJSONString reqBody "password"

      case (mUsername, mPassword) of
        (Nothing, _) -> do
          status badRequest400
          json $ object ["error" .= ("Username required" :: String)]
        (_, Nothing) -> do
          status badRequest400
          json $ object ["error" .= ("Password required" :: String)]
        (Just user, Just pass) -> do
          if not (isValidUsername user)
            then do
              status badRequest400
              json $ object ["error" .= ("Invalid username" :: String)]
            else if length pass < 8
              then do
                status badRequest400
                json $ object ["error" .= ("Password too short" :: String)]
              else do
                state <- getState
                let existingUser = find (\(_, u) -> username u == user) (Map.toList (users state))
                case existingUser of
                  Just _ -> do
                    status conflict409
                    json $ object ["error" .= ("Username already exists" :: String)]
                  Nothing -> do
                    let userUID = nextUserId state
                    let newUser = User userUID user pass
                    modifyState $ \st ->
                      st { users = Map.insert userUID newUser (users st)
                         , nextUserId = nextUserId st + 1
                         }

                    status created201
                    json $ object
                      [ "id" .= userUID
                      , "username" .= user
                      ]

    -- POST /login
    post "/login" $ do
      reqBody <- jsonData @Value
      let mUsername = getJSONString reqBody "username"
          mPassword = getJSONString reqBody "password"

      case (mUsername, mPassword) of
        (Nothing, _) -> do
          status badRequest400
          json $ object ["error" .= ("Username required" :: String)]
        (_, Nothing) -> do
          status badRequest400
          json $ object ["error" .= ("Password required" :: String)]
        (Just user, Just pass) -> do
          state <- getState
          let matchingUsers = filter (\u -> username u == user && password u == pass) (Map.elems (users state))

          case matchingUsers of
            [foundUser] -> do
              newSessionId <- liftIO generateSessionId

              modifyState $ \st ->
                let newSession = AuthSession newSessionId (userId foundUser)
                in st { sessions = Map.insert newSessionId newSession (sessions st) }

              setHeader "Set-Cookie" (TL.pack $ "session_id=" ++ newSessionId ++ "; Path=/; HttpOnly")

              status ok200
              json $ object
                [ "id" .= userId foundUser
                , "username" .= username foundUser
                ]
            [] -> do
              status unauthorized401
              json $ object ["error" .= ("Invalid credentials" :: String)]

    -- POST /logout
    post "/logout" $ do
      authenticateAction $ \authUserId -> do
        maybeCookies <- header "Cookie"
        let mSessionId = getSessionIdFromCookie maybeCookies
        whenJust mSessionId $ \sessionId ->
          modifyState $ \st ->
            st { sessions = Map.delete sessionId (sessions st) }
        status ok200
        json $ object []

    -- GET /me
    get "/me" $ do
      authenticateAction $ \userId -> do
        state <- getState
        let user = fromMaybe (error $ "User not found for ID: " ++ show userId) $ Map.lookup userId (users state)
        json user

    -- PUT /password
    put "/password" $ do
      authenticateAction $ \userId -> do
        reqBody <- jsonData @Value
        let mOldPassword = getJSONString reqBody "old_password"
            mNewPassword = getJSONString reqBody "new_password"

        case (mOldPassword, mNewPassword) of
          (Nothing, _) -> do
            status badRequest400
            json $ object ["error" .= ("Old password required" :: String)]
          (_, Nothing) -> do
            status badRequest400
            json $ object ["error" .= ("New password required" :: String)]
          (Just oldPass, Just newPass) -> do
            if length newPass < 8
              then do
                status badRequest400
                json $ object ["error" .= ("Password too short" :: String)]
              else do
                state <- getState
                let user = fromMaybe (error $ "User not found for ID: " ++ show userId) $ Map.lookup userId (users state)
                if password user /= oldPass
                  then do
                    status unauthorized401
                    json $ object ["error" .= ("Invalid credentials" :: String)]
                  else do
                    modifyState $ \st ->
                      let userToUpdate = fromMaybe (error $ "User not found for ID: " ++ show userId) $ Map.lookup userId (users st)
                          updatedUser = userToUpdate { password = newPass }
                      in st { users = Map.insert userId updatedUser (users st) }
                    status ok200
                    json $ object []

    -- GET /todos
    get "/todos" $ do
      authenticateAction $ \userId -> do
        state <- getState
        let userTodos = sortBy (compare `on` todoId) $ filter (\t -> ownerId t == userId) (Map.elems (todos state))
        json userTodos

    -- POST /todos
    post "/todos" $ do
      authenticateAction $ \userId -> do
        state <- getState  -- Capture state before proceeding to avoid inconsistencies 
        reqBody <- jsonData @Value
        let mTitle = getJSONString reqBody "title"
            mDesc = getJSONString reqBody "description"
            descStr = fromMaybe "" mDesc

        case mTitle of
          Nothing -> do
            status badRequest400
            json $ object ["error" .= ("Title is required" :: String)]
          Just titleStr -> do
            if null titleStr
              then do
                status badRequest400
                json $ object ["error" .= ("Title is required" :: String)]
              else do
                currTime <- liftIO getCurrentTimeFormatted
                let todoId = nextTodoId state
                let newTodo = Todo todoId titleStr descStr False currTime currTime userId
                modifyState $ \st ->
                  st { todos = Map.insert todoId newTodo (todos st)
                     , nextTodoId = nextTodoId st + 1
                     }

                status created201
                json newTodo

    -- GET /todos/:id
    get "/todos/:id" $ do
      maybeTodoId <- getTodoIdFromPath
      case maybeTodoId of
        Nothing -> do
          status badRequest400
          json $ object ["error" .= ("Invalid ID format" :: String)]
        Just todoId -> 
          authenticateAction $ \userId -> do
            state <- getState
            case Map.lookup todoId (todos state) >>= \t -> if ownerId t == userId then Just t else Nothing of
              Just t -> json t
              Nothing -> do
                status notFound404
                json $ object ["error" .= ("Todo not found" :: String)]

    -- PUT /todos/:id
    put "/todos/:id" $ do
      maybeTodoId <- getTodoIdFromPath
      case maybeTodoId of
        Nothing -> do
          status badRequest400
          json $ object ["error" .= ("Invalid ID format" :: String)]
        Just todoId -> do
          reqBody <- jsonData @Value
          authenticateAction $ \userId -> do
            state <- getState
            case Map.lookup todoId (todos state) >>= \t -> if ownerId t == userId then Just t else Nothing of
              Nothing -> do
                status notFound404
                json $ object ["error" .= ("Todo not found" :: String)]

              Just existingTodo -> do
                let mNewTitle = getJSONString reqBody "title"
                    mNewDesc = getJSONString reqBody "description"
                    mNewCompleted = getJSONBool reqBody "completed"

                case mNewTitle of
                  Just "" -> do
                    status badRequest400
                    json $ object ["error" .= ("Title is required" :: String)]
                  Just newTitle -> do
                    currTime <- liftIO getCurrentTimeFormatted
                    let updatedTodo = existingTodo
                          { title = newTitle
                          , description = fromMaybe (description existingTodo) mNewDesc
                          , completed = fromMaybe (completed existingTodo) mNewCompleted
                          , updatedAt = currTime
                          }

                    modifyState $ \st ->
                      st { todos = Map.insert todoId updatedTodo (todos st) }

                    json updatedTodo
                  Nothing -> do
                    currTime <- liftIO getCurrentTimeFormatted
                    let updatedTodo = existingTodo
                          { description = fromMaybe (description existingTodo) mNewDesc
                          , completed = fromMaybe (completed existingTodo) mNewCompleted
                          , updatedAt = currTime
                          }

                    modifyState $ \st ->
                      st { todos = Map.insert todoId updatedTodo (todos st) }

                    json updatedTodo

    -- DELETE /todos/:id  
    delete "/todos/:id" $ do
      maybeTodoId <- getTodoIdFromPath
      case maybeTodoId of
        Nothing -> do
          status badRequest400
          json $ object ["error" .= ("Invalid ID format" :: String)]
        Just todoId -> 
          authenticateAction $ \userId -> do
            state <- getState
            case Map.lookup todoId (todos state) >>= \t -> if ownerId t == userId then Just t else Nothing of
              Nothing -> do
                status notFound404
                json $ object ["error" .= ("Todo not found" :: String)]
              Just _ -> do
                modifyState $ \st ->
                  st { todos = Map.delete todoId (todos st) }
                status noContent204

-- Helper function to perform operation only when Just value is provided
whenJust :: Maybe a -> (a -> ActionM ()) -> ActionM ()
whenJust Nothing _ = return ()
whenJust (Just x) f = f x