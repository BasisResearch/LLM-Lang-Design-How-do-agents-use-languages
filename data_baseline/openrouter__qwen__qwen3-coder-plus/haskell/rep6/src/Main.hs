{-# LANGUAGE OverloadedStrings #-}

import Web.Scotty
import Network.Wai.Middleware.Cors
import Network.HTTP.Types.Status 
import Data.Aeson
import Data.Monoid ((<>))
import qualified Data.Text.Lazy as L
import qualified Data.Text as T
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (isNothing, fromMaybe)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map.Strict as Map
import System.Environment (getArgs)
import Data.List (sortBy)
import Types
import Models
import Auth
import Data.Time
import Control.Concurrent.STM
import Network.HTTP.Types.Header
import Text.Read (readMaybe)

-- Extract port from command line arguments
extractPort :: [String] -> (Maybe Int, [String])
extractPort [] = (Nothing, [])
extractPort ("--port":portStr:rest) = 
  case reads portStr of
    [(n, "")] -> (Just n, rest)
    _ -> (Nothing, rest)
extractPort (x:xs) = 
  let (portOpt, remaining) = extractPort xs
  in (portOpt, x:remaining)

main :: IO ()
main = do  
  storage <- initStorage
  args <- getArgs
  
  let (portOpt, _) = extractPort args
  let port = case portOpt of
        Just p -> p
        Nothing -> 3000  -- Default port if none specified

  putStrLn $ "Starting server on port " ++ show port
  scotty port $ do
    middleware myCorsPolicy

    post "/register" $ handleRegister storage
    post "/login" $ handleLogin storage
    post "/logout" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> handleLogout storage userId
        Nothing -> sendAuthError
    get "/me" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> handleMe storage userId
        Nothing -> sendAuthError
    put "/password" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> handleChangePassword storage userId
        Nothing -> sendAuthError
    get "/todos" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> handleGetTodos storage userId
        Nothing -> sendAuthError
    post "/todos" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> handleCreateTodo storage userId
        Nothing -> sendAuthError
    get "/todos/:id" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> do
          rawTodoId <- param "id"
          case readMaybe (L.unpack rawTodoId) of
            Just todoId -> handleGetTodoById storage userId todoId
            Nothing -> do
              status status400
              json $ ErrorResponse "Invalid ID format"
        Nothing -> sendAuthError
    put "/todos/:id" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> do
          rawTodoId <- param "id"
          case readMaybe (L.unpack rawTodoId) of
            Just todoId -> handleUpdateTodo storage userId todoId
            Nothing -> do
              status status400
              json $ ErrorResponse "Invalid ID format"
        Nothing -> sendAuthError
    delete "/todos/:id" $ do
      mUserId <- getAuthenticatedUser storage
      case mUserId of
        Just userId -> do
          rawTodoId <- param "id"
          case readMaybe (L.unpack rawTodoId) of
            Just todoId -> handleDeleteTodo storage userId todoId
            Nothing -> do
              status status400
              json $ ErrorResponse "Invalid ID format"
        Nothing -> sendAuthError

-- Function to extract authenticated user ID using the correct Scotty request API
getAuthenticatedUser :: StorageState -> ActionM (Maybe Int)
getAuthenticatedUser storage = do
  -- In Scotty, header might return Lazy Text
  mCookiesHeader <- header "Cookie"
  case mCookiesHeader of
    Just cookieValue -> do  
      -- Since header returns Lazy Text, we need to convert to String
      let cookieStr = L.unpack cookieValue  
      let cookies = parseCookies cookieStr
      case lookup "session_id" cookies of
        Just sessionId -> liftIO $ atomically $ findSessionUser sessionId storage
        Nothing -> return Nothing
    Nothing -> return Nothing

-- Send authentication error consistently
sendAuthError :: ActionM ()
sendAuthError = do
  status status401
  json $ ErrorResponse "Authentication required"

-- Parse cookies from header string
parseCookies :: String -> [(String, String)]
parseCookies cookieStr = 
  map parseCookiePair $ splitOn ";" (filter (/= ' ') cookieStr)
  where
    parseCookiePair s = let parts = break (== '=') s
                        in case parts of
                          (name, '=':value) -> (name, value)
                          (name, _) -> (name, "")
    break f s = let (x,y) = break f s in (x, if null y then y else tail y)
    splitOn delimiter str = foldr f [[]] str
      where
        f c l@(x:xs) | c == head delimiter = [head delimiter] : l
                     | otherwise = (c:x) : xs

handleRegister :: StorageState -> ActionM ()
handleRegister storage = do
  RegisterRequest username password <- jsonData
  
  -- Validations
  if not (validateUsername username)
    then do
      status status400
      json $ ErrorResponse "Invalid username"
    else if not (validatePassword password)
      then do
        status status400
        json $ ErrorResponse "Password too short"
      else do
        mResult <- liftIO $ atomically $ createUser username password storage
        
        case mResult of
          Nothing -> do
            status status409
            json $ ErrorResponse "Username already exists"
          Just user -> do
            status status201
            json user

handleLogin :: StorageState -> ActionM ()
handleLogin storage = do
  LoginRequest username password <- jsonData
  
  validUserId <- liftIO $ atomically $ validateUser username password storage
  
  case validUserId of
    Nothing -> do
      status status401
      json $ ErrorResponse "Invalid credentials"
    Just userId -> do
      -- Create a session
      sessionId <- liftIO generateSessionId
      liftIO $ atomically $ Models.addSession sessionId userId storage  -- disambiguate addSession
      
      -- Find the user to return their info
      usersMap <- liftIO $ readTVarIO (users storage)
      case Map.lookup username usersMap of
        Just user -> do
          setHeader "Set-Cookie" $ L.fromStrict $ BS.pack $ "session_id=" ++ sessionId ++ "; Path=/; HttpOnly"
          json user
        Nothing -> do
          status status500
          json $ ErrorResponse "Internal server error"

handleLogout :: StorageState -> Int -> ActionM ()
handleLogout storage _userId = do
  -- Get the cookie header to find and remove the session
  mCookiesHeader <- header "Cookie"
  case mCookiesHeader of
    Just cookieValue -> do
      let cookieStr = L.unpack cookieValue
      let cookies = parseCookies cookieStr
      case lookup "session_id" cookies of
        Just sessionId -> do
          wasRemoved <- liftIO $ atomically $ removeSession sessionId storage
          if wasRemoved
            then json (Object mempty) -- Successful logout response {}
            else sendAuthError
        Nothing -> sendAuthError
    Nothing -> sendAuthError

handleMe :: StorageState -> Int -> ActionM ()
handleMe storage userIdIn = do
  -- Find the user with this userId
  usersMap <- liftIO $ readTVarIO (users storage)
  -- We need to look up the user by their ID, not by username
  let allUsers = Map.elems usersMap
  let mUser = case filter (\u -> userId u == userIdIn) allUsers of
                [] -> Nothing
                (u:_) -> Just u  -- The filtered user that matches the provided ID
  
  case mUser of
    Just user -> json user
    Nothing -> do
      status status401
      json $ ErrorResponse "User not found"

handleChangePassword :: StorageState -> Int -> ActionM ()
handleChangePassword storage userId = do
  ChangePasswordRequest oldPwd newPwd <- jsonData
  
  if not (validatePassword newPwd)
    then do
      status status400
      json $ ErrorResponse "Password too short"
    else do
      success <- liftIO $ atomically $ updatePassword userId oldPwd newPwd storage
      
      if success
        then json (Object mempty)
        else do
          status status401
          json $ ErrorResponse "Invalid credentials"

handleGetTodos :: StorageState -> Int -> ActionM ()
handleGetTodos storage userId = do
  todosForUser <- liftIO $ atomically $ getTodosByUser userId storage
  -- Sort by id as per specification: Returns only todos belonging to the authenticated user, ordered by id ascending
  let sortedTodos = sortBy (\a b -> compare (todoId a) (todoId b)) todosForUser
  json sortedTodos

handleCreateTodo :: StorageState -> Int -> ActionM ()
handleCreateTodo storage userId = do
  CreateTodoRequest title description <- jsonData
  
  if null title
    then do
      status status400
      json $ ErrorResponse "Title is required"
    else do
      mNewTodo <- liftIO $ createTodo userId title description storage
      case mNewTodo of
        Just todo -> do
          status status201
          json todo
        Nothing -> do
          status status500
          json $ ErrorResponse "Failed to create todo"

handleGetTodoById :: StorageState -> Int -> Int -> ActionM ()  
handleGetTodoById storage userId todoId = do
  mTodoData <- liftIO $ atomically $ getTodoById todoId storage
  
  case mTodoData of
    Just (ownerId, todo) -> 
      if ownerId == userId
        then json todo
        else do
          status status404
          json $ ErrorResponse "Todo not found"
    Nothing -> do
      status status404
      json $ ErrorResponse "Todo not found"

handleUpdateTodo :: StorageState -> Int -> Int -> ActionM ()
handleUpdateTodo storage userId todoId = do
  req@UpdateTodoRequest{} <- jsonData
  
  mUpdatedTodo <- liftIO $ updateTodo userId todoId req storage
  
  case mUpdatedTodo of
    Just todo -> json todo
    Nothing -> do
      status status404
      json $ ErrorResponse "Todo not found"

handleDeleteTodo :: StorageState -> Int -> Int -> ActionM ()
handleDeleteTodo storage userId todoId = do
  success <- liftIO $ atomically $ deleteTodo userId todoId storage
  
  if success
    then status status204
    else do
      status status404
      json $ ErrorResponse "Todo not found"

myCorsPolicy = cors (const $ Just simpleCorsResourcePolicy
  { corsMethods = ["GET", "POST", "PUT", "DELETE"]
  , corsOrigins = Nothing -- Allow all origins
  })