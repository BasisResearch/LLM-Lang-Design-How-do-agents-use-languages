{-# LANGUAGE OverloadedStrings #-}
module Main where

import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.HTTP.Types as HTTP
import Web.Scotty
import Network.HTTP.Types.Header (Header)
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map.Strict as Map
import Data.Aeson
import Data.Time
import System.Random
import Data.IORef
import Data.List (find, sortBy)
import Data.Function (on)
import System.Environment (getArgs)
import qualified Network.Wai as Wai
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)

-- Define data types
newtype UserId = UserId Int deriving (Show, Eq, Ord)
newtype TodoId = TodoId Int deriving (Show, Eq, Ord)

instance FromJSON UserId where
  parseJSON = fmap UserId . parseJSON

instance ToJSON UserId where
  toJSON (UserId i) = toJSON i

instance FromJSON TodoId where
  parseJSON = fmap TodoId . parseJSON

instance ToJSON TodoId where
  toJSON (TodoId i) = toJSON i

data User = User 
  { userIdField :: UserId
  , usernameField :: String
  , userPasswordField :: String
  } deriving (Show)

instance ToJSON User where
  toJSON u = object ["id" .= userIdField u, "username" .= usernameField u]

data Todo = Todo
  { todoIdField :: TodoId
  , titleField :: String
  , descriptionField :: String
  , completedField :: Bool
  , createdAtField :: UTCTime
  , updatedAtField :: UTCTime
  } deriving (Show)

instance ToJSON Todo where
  toJSON t = object 
    [ "id" .= todoIdField t
    , "title" .= titleField t
    , "description" .= descriptionField t
    , "completed" .= completedField t
    , "created_at" .= formatTimestamp (createdAtField t)
    , "updated_at" .= formatTimestamp (updatedAtField t)
    ]

data AppState = AppState 
  { stateUsers :: IORef [(UserId, User)]
  , stateTodos :: IORef [(TodoId, Todo, UserId)] 
  , stateSessions :: IORef (Map.Map String UserId) 
  }

-- Format timestamp helper
formatTimestamp :: UTCTime -> String
formatTimestamp = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- Request data types for parsing JSON bodies
data NewUserReq = NewUserReq { reqUsername :: String, reqPassword :: String }
data LoginReq = LoginReq { loginUsername :: String, loginPassword :: String }
data PasswordChgReq = PasswordChgReq { oldPassword :: String, newPassword :: String }
data TodoReq = TodoReq { reqTitle :: String, reqDescription :: String }
data TodoUpdReq = TodoUpdReq { updTitle :: Maybe String, updDescription :: Maybe String, updCompleted :: Maybe Bool }

-- Decoders
instance FromJSON NewUserReq where
  parseJSON = withObject "newUser" $ \o -> do
    username <- o .: "username"
    password <- o .: "password"
    return $ NewUserReq username password

instance FromJSON LoginReq where
  parseJSON = withObject "login" $ \o -> do
    username <- o .: "username"
    password <- o .: "password"
    return $ LoginReq username password

instance FromJSON PasswordChgReq where
  parseJSON = withObject "passwordChange" $ \o -> do
    oldpw <- o .: "old_password"
    newpw <- o .: "new_password"
    return $ PasswordChgReq oldpw newpw

instance FromJSON TodoReq where
  parseJSON = withObject "todoRequest" $ \o -> do
    title <- o .: "title"
    desc <- o .:? "description" .!= ""
    return $ TodoReq title desc

instance FromJSON TodoUpdReq where
  parseJSON = withObject "todoUpdateRequest" $ \o -> do
    title <- o .:? "title"
    desc <- o .:? "description"
    comp <- o .:? "completed"
    return $ TodoUpdReq title desc comp

-- Check if username is valid
isValidUsername :: String -> Bool
isValidUsername s = length s >= 3 && length s <= 50 && all isValidChar s
  where
    isValidChar c = c `elem` (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "_")

-- Generate session ID
generateSessionId :: IO String
generateSessionId = do
  gen <- newStdGen
  let randomValues = take 32 (randomRs (0::Int, 15) gen)
      hexChars = "0123456789abcdef"
      randomChars = map (hexChars !!) randomValues
  return randomChars

-- Get cookie header from request
getCookiesFromHeaders :: [Header] -> [String]
getCookiesFromHeaders headers = 
  [ BS.unpack val | (name, val) <- headers, name == "cookie" || name == "Cookie"]

getCookieValue :: String -> Maybe String
getCookieValue cookieStr = 
  let pairs = map (span (/= '=')) $ splitOn ';' $ filter (/= ' ') cookieStr
      found = find (\(key, _) -> key == "session_id") pairs
  in case found of
       Nothing -> Nothing
       Just (_, val) -> if null val then Nothing else Just (tail val)  -- Remove '='

splitOn :: Eq a => a -> [a] -> [[a]]
splitOn x [] = [[]]
splitOn x (y:ys) = 
  if x == y 
    then [] : splitOn x ys
    else case splitOn x ys of
           [] -> [[y]]
           z:zs -> (y:z) : zs

-- Get session ID
getSessionId :: ActionM (Maybe String)
getSessionId = do
  req <- request
  let cookies = getCookiesFromHeaders $ Wai.requestHeaders req
  if null cookies 
    then return Nothing
    else case getCookieValue (head cookies) of
         Nothing -> return Nothing
         Just val -> return (Just val)

-- Get current logged in user ID
requireAuth :: AppState -> ActionM UserId
requireAuth appState = do
  mSessionId <- getSessionId
  case mSessionId of
    Nothing -> do
      json $ object ["error" .= String "Authentication required"]
      status HTTP.status401
      finish
    Just sessionId -> do
      sessions <- liftIO $ readIORef (stateSessions appState)
      case Map.lookup sessionId sessions of
        Nothing -> do
          json $ object ["error" .= String "Authentication required"]
          status HTTP.status401
          finish
        Just userId -> return userId

main :: IO ()
main = do
  args <- getArgs
  let parsedArgs = parseArgs args
      port = fromMaybe 3000 $ lookup "port" parsedArgs
  
  putStrLn $ "Starting server on port " ++ show port
  
  -- Initialize shared state
  initialUsers <- newIORef []
  initialTodos <- newIORef []
  initialSessions <- newIORef Map.empty
  let appState = AppState initialUsers initialTodos initialSessions
  
  -- Start the server
  scotty port $ myApp appState

parseArgs :: [String] -> [(String, Int)]
parseArgs [] = []
parseArgs ("--port":val:rest) = ("port", read val) : parseArgs rest
parseArgs (_:rest) = parseArgs rest

myApp :: AppState -> ScottyM ()
myApp appState = do
  -- Log all requests
  middleware $ \app req respond -> do
    putStrLn $ show (Wai.requestMethod req) ++ " " ++ Wai.rawPathInfo req
    app req respond

  -- Registration endpoint
  post "/register" $ do
    newUser <- jsonData :: ActionM NewUserReq
    
    let username = reqUsername newUser
        password = reqPassword newUser
    
    -- Validate input
    if not (isValidUsername username)
      then do
        status HTTP.status400
        json $ object ["error" .= String "Invalid username"]
      else if length password < 8
        then do
          status HTTP.status400
          json $ object ["error" .= String "Password too short"]
        else do
          users <- liftIO $ readIORef (stateUsers appState)
          let existingUser = find (\(_, u) -> usernameField u == username) users
          
          case existingUser of
            Just _ -> do
              status HTTP.status409
              json $ object ["error" .= String "Username already exists"]
            Nothing -> do
              let nextId = case reverse $ map fst users of
                    [] -> 1
                    (UserId maxId):_ -> maxId + 1
                  
              let newUserId = UserId nextId
                  user = User newUserId username password
                  
              liftIO $ modifyIORef (stateUsers appState) (++[(newUserId, user)])
              
              status HTTP.status201
              json user

  -- Login endpoint  
  post "/login" $ do
    loginReq <- jsonData :: ActionM LoginReq
    
    let usernameInput = loginUsername loginReq
        passwordInput = loginPassword loginReq
    
    users <- liftIO $ readIORef (stateUsers appState)
    let matchingUser = find (\(_, u) -> usernameField u == usernameInput) users
    
    case matchingUser of
      Nothing -> do
        status HTTP.status401
        json $ object ["error" .= String "Invalid credentials"]
      Just (userId, user) ->
        if userPasswordField user == passwordInput
          then do
            sessionId <- liftIO generateSessionId
            liftIO $ modifyIORef (stateSessions appState) (Map.insert sessionId userId)
            
            let cookieHeader = "session_id=" ++ sessionId ++ "; Path=/; HttpOnly"
            addHeader "Set-Cookie" $ BS.pack cookieHeader
            
            status HTTP.status200
            json $ object ["id" .= userId, "username" .= String (T.pack (usernameField user))]
          else do
            status HTTP.status401
            json $ object ["error" .= String "Invalid credentials"]

  -- Protected routes with auth check
  let protectedRoute action = requireAuth appState >>= action

  -- Logout endpoint
  post "/logout" $ protectedRoute $ \_ -> do
    mSessionId <- getSessionId
    case mSessionId of
      Just sessionId -> liftIO $ modifyIORef (stateSessions appState) (Map.delete sessionId)
      Nothing -> return ()
    
    json $ object []
  
  -- Get current user
  get "/me" $ protectedRoute $ \uid -> do
    users <- liftIO $ readIORef (stateUsers appState)
    let userResult = find (\(userId, _) -> userId == uid) users
    case userResult of
      Nothing -> do
        status HTTP.status404
        json $ object ["error" .= String "User not found"]
      Just (_, u) -> json u

  -- Change password
  put "/password" $ protectedRoute $ \uid -> do
    changePwdReq <- jsonData :: ActionM PasswordChgReq
    
    let oldPasswordInput = oldPassword changePwdReq
        newPasswordInput = newPassword changePwdReq
    
    if length newPasswordInput < 8
      then do
        status HTTP.status400
        json $ object ["error" .= String "Password too short"]
      else do
        users <- liftIO $ readIORef (stateUsers appState)
        let userResult = find (\(userId, _) -> userId == uid) users
        case userResult of
          Nothing -> do
            status HTTP.status404
            json $ object ["error" .= String "User not found"]
          Just (_, u) ->
            if userPasswordField u /= oldPasswordInput
              then do
                status HTTP.status401
                json $ object ["error" .= String "Invalid credentials"]
              else do
                let updateUserPass (userId, user) = 
                      if userId == uid then (userId, user { userPasswordField = newPasswordInput }) else (userId, user)
                    
                liftIO $ modifyIORef (stateUsers appState) (map updateUserPass)
                
                json $ object []

  -- Get user's todos
  get "/todos" $ protectedRoute $ \uid -> do
    todos <- liftIO $ readIORef (stateTodos appState)
    let userTodos = [todo | (_, todo, owner) <- todos, owner == uid]
    let sortedTodos = sortBy (compare `on` todoIdField) userTodos
    json sortedTodos

  -- Add a new todo
  post "/todos" $ protectedRoute $ \uid -> do
    todoReq <- jsonData :: ActionM TodoReq
    
    let titleInput = reqTitle todoReq
        descInput = reqDescription todoReq
    
    if null titleInput
      then do
        status HTTP.status400
        json $ object ["error" .= String "Title is required"]
      else do
        todos <- liftIO $ readIORef (stateTodos appState)
        nextId <- case reverse $ map (\(tId, _, _) -> tId) todos of
          [] -> return 1
          (TodoId maxId):_ -> return $ maxId + 1
        
        now <- liftIO getCurrentTime
        
        let newTodoId = TodoId nextId
            newTodo = Todo 
              { todoIdField = newTodoId
              , titleField = titleInput
              , descriptionField = descInput
              , completedField = False
              , createdAtField = now
              , updatedAtField = now
              }
        
        liftIO $ modifyIORef (stateTodos appState) (++[(newTodoId, newTodo, uid)])
        
        status HTTP.status201
        json newTodo

  -- Get specific todo
  get "/todos/:id" $ do
    requestedId <- param "id"
    let requestedTodoId = TodoId requestedId
    
    -- Auth protection
    uid <- requireAuth appState
    
    todos <- liftIO $ readIORef (stateTodos appState)
    let matchingTodo = find (\(todoId, _, owner) -> todoId == requestedTodoId && owner == uid) todos
    
    case matchingTodo of
      Nothing -> do
        status HTTP.status404
        json $ object ["error" .= String "Todo not found"]
      Just (_, todo, _) -> json todo

  -- Update specific todo
  put "/todos/:id" $ do
    requestedId <- param "id"
    let requestedTodoId = TodoId requestedId
    updateReq <- jsonData :: ActionM TodoUpdReq
    
    -- Auth protection
    uid <- requireAuth appState
    
    todos <- liftIO $ readIORef (stateTodos appState)
    let matchingTodo = find (\(todoId, _, owner) -> todoId == requestedTodoId && owner == uid) todos
    
    case matchingTodo of
      Nothing -> do
        status HTTP.status404
        json $ object ["error" .= String "Todo not found"]
      Just (_, originalTodo, _) -> do
        let newTitle = fromMaybe (titleField originalTodo) (updTitle updateReq)
        
        if newTitle == ""
          then do
            status HTTP.status400
            json $ object ["error" .= String "Title is required"]
          else do
            now <- liftIO getCurrentTime
            
            let updatedTodo = originalTodo 
                  { titleField = fromMaybe (titleField originalTodo) (updTitle updateReq)
                  , descriptionField = fromMaybe (descriptionField originalTodo) (updDescription updateReq)
                  , completedField = fromMaybe (completedField originalTodo) (updCompleted updateReq)
                  , updatedAtField = now
                  }
                  
            let updateFunc (tid, t, tuid) = 
                  if tid == requestedTodoId then (tid, updatedTodo, tuid) else (tid, t, tuid)
                  
            liftIO $ modifyIORef (stateTodos appState) (map updateFunc)
            
            json updatedTodo

  -- Delete specific todo
  delete "/todos/:id" $ do
    requestedId <- param "id"
    let requestedTodoId = TodoId requestedId
    
    -- Auth protection
    uid <- requireAuth appState
    
    todos <- liftIO $ readIORef (stateTodos appState)
    let matchingTodos = filter (\(todoId, _, owner) -> todoId == requestedTodoId && owner == uid) todos
    
    if null matchingTodos
      then do
        status HTTP.status404
        json $ object ["error" .= String "Todo not found"]
      else do
        liftIO $ modifyIORef (stateTodos appState) 
          (filter (\(todoId, _, owner) -> todoId /= requestedTodoId || owner /= uid))
        status HTTP.status204  -- No content