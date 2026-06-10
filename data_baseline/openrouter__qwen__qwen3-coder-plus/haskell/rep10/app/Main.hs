{-# LANGUAGE OverloadedStrings #-}

import qualified Network.HTTP.Types as HTTP
import qualified Web.Scotty as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE  
import qualified Data.ByteString.Lazy as BL
import Data.Aeson (encode, decode, Value(..), (.=), object, ToJSON, FromJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.String (fromString)
import Network.HTTP.Types.Status 
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent.STM  
import qualified Data.Map as Map
import System.Environment (getArgs)
import Text.Read (readMaybe)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.List (find)
import System.Random (randomIO)
import Data.Time (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import qualified Crypto.Hash as CH
import qualified Data.ByteArray.Encoding as BAE
import qualified Data.ByteString.Char8 as BS8

-- Data Models
data User = User 
  { userId :: Int
  , username :: String 
  , passwordHash :: String
  } deriving (Show, Eq)

instance ToJSON User

data Todo = Todo
  { todoId :: Int
  , todoTitle :: String
  , todoDescription :: String  
  , todoCompleted :: Bool
  , createdAt :: String
  , updatedAt :: String
  , ownerId :: Int  -- Reference to user who owns this todo
  } deriving (Show, Eq)

instance ToJSON Todo

data RegisterRequest = RegisterRequest 
  { regUsername :: T.Text
  , regPassword :: T.Text
  } deriving (Show)

instance FromJSON RegisterRequest

data LoginRequest = LoginRequest
  { loginUsername :: T.Text 
  , loginPassword :: T.Text
  } deriving (Show)

instance FromJSON LoginRequest

data ChangePasswordRequest = ChangePasswordRequest
  { oldPassword :: T.Text
  , newPassword :: T.Text
  } deriving (Show)

instance FromJSON ChangePasswordRequest

data TodoUpdateRequest = TodoUpdateRequest
  { updateTitle :: Maybe T.Text
  , updateDescription :: Maybe T.Text
  , updateCompleted :: Maybe Bool
  } deriving (Show)

instance FromJSON TodoUpdateRequest

-- Type aliases  
type PasswordHash = String
type SessionID = String

-- Application State
data AppState = AppState
  { users :: TVar [(Int, User)]           -- List of (UserId, User) pairs
  , todos :: TVar [(Int, Todo)]           -- List of (TodoId, Todo) pairs  
  , sessions :: TVar (Map.Map String Int)  -- Map sessionID to user ID
  , nextUserId :: TVar Int               -- Counter for next user ID  
  , nextTodoId :: TVar Int               -- Counter for next todo ID
  }

-- Initialize application state
initAppState :: IO AppState
initAppState = do
  usersVar <- newTVarIO []
  todosVar <- newTVarIO []
  sessionsVar <- newTVarIO Map.empty
  userIdCounter <- newTVarIO 1
  todoIdCounter <- newTVarIO 1
  return $ AppState usersVar todosVar sessionsVar userIdCounter todoIdCounter

-- | Hash password using SHA256
hashPassword :: String -> String
hashPassword p = BAE.convertToBase BAE.Base16 $ CH.hashWith CH.SHA256 $ BS8.pack p

-- | Validate username format (3-50 chars, alphanumeric and underscore) 
validateUsername :: String -> Bool
validateUsername username = 
  length username >= 3 && length username <= 50 && all isValidChar username
  where
    isValidChar c = c `elem` ['a'..'z'] || c `elem` ['A'..'Z'] || c `elem` ['0'..'9'] || c == '_'

-- | Get current ISO8601 formatted time
getISOString :: IO String
getISOString = do
  now <- getCurrentTime
  return $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

-- Helper to find argument value after flag
findArg :: String -> [String] -> Maybe String
findArg flag args = go args
  where
    go [] = Nothing
    go (x:xs) 
      | x == flag = case xs of
                      (val:_) -> Just val
                      _ -> Nothing
      | otherwise = go xs

-- Generate secure session ID
generateSessionId :: IO SessionID
generateSessionId = do
  bytes <- mapM (\_ -> randomIO :: IO Int) [1..8]
  return $ concatMap show bytes

-- Main function
main :: IO ()
main = do
    args <- getArgs
    
    -- Parse --port argument
    let port = case findArg "--port" args of
                 Just portStr -> case readMaybe portStr of
                                   Just p -> fromInteger p
                                   Nothing -> 8080
                 Nothing -> 8080
                 
    putStrLn $ "Starting server on port " ++ show port
    
    appState <- initAppState
    
    -- Start the Scotty server (will listen on 0.0.0.0:port)
    S.scotty port $ do
      S.middleware $ \req f -> f req
      app appState

app :: AppState -> S.ScottyM ()
app state = do
    -- POST /register
    S.post "/register" $ do
        S.setHeader "Content-Type" "application/json"
        registerReq <- S.jsonData :: S.ActionM RegisterRequest
        result <- liftIO $ registerUser state (T.unpack $ regUsername registerReq) (T.unpack $ regPassword registerReq)
        case result of
            Left errorMsg -> do
                S.status $ case errorMsg of
                    "Invalid username" -> HTTP.status400
                    "Password too short" -> HTTP.status400
                    "Username already exists" -> HTTP.status409
                    _ -> HTTP.status400
                S.json $ object ["error" .= (fromString errorMsg)]
            Right user -> do
                S.status HTTP.status201
                S.json user
    
    -- POST /login
    S.post "/login" $ do
        S.setHeader "Content-Type" "application/json"
        loginReq <- S.jsonData :: S.ActionM LoginRequest
        result <- liftIO $ authenticateUser state (T.unpack $ loginUsername loginReq) (T.unpack $ loginPassword loginReq)
        case result of
            Left errorMsg -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString errorMsg)]
            Right (user, sessionId) -> do
                S.setHeader "Set-Cookie" (T.pack $ "session_id=" ++ sessionId ++ "; Path=/; HttpOnly")
                S.json user
                
    -- POST /logout - protected
    S.post "/logout" $ do
        S.setHeader "Content-Type" "application/json"
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just _ -> do
                headers <- S.header "cookie"
                case headers of
                    Nothing -> return ()
                    Just cookieHdr -> 
                      let pairs = parseCookieString (TE.decodeUtf8 $ BL.toStrict cookieHdr)
                      in case lookup "session_id" pairs of
                           Nothing -> return ()
                           Just sessionId -> liftIO $ removeSession state (T.unpack sessionId)
                S.status HTTP.status200
                S.json $ object []
          
    -- GET /me - protected
    S.get "/me" $ do
        S.setHeader "Content-Type" "application/json"
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just user -> S.json user
            
    -- PUT /password - protected
    S.put "/password" $ do
        S.setHeader "Content-Type" "application/json"
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just user -> do
                passReq <- S.jsonData :: S.ActionM ChangePasswordRequest
                if T.length (newPassword passReq) < 8
                    then do
                        S.status HTTP.status400
                        S.json $ object ["error" .= (fromString "Password too short")]
                    else do
                        changeResult <- liftIO $ changeUserPassword state (userId user) (T.unpack $ oldPassword passReq) (T.unpack $ newPassword passReq)
                        case changeResult of
                            Left errorMsg -> do
                                S.status HTTP.status401
                                S.json $ object ["error" .= (fromString errorMsg)]
                            Right () -> S.status HTTP.status200  -- Success, 200 response with empty body
            
    -- GET /todos - protected
    S.get "/todos" $ do
        S.setHeader "Content-Type" "application/json"
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just user -> do
                todos' <- liftIO $ getUserTodos state (userId user)
                S.json todos'
    
    -- POST /todos - protected
    S.post "/todos" $ do
        S.setHeader "Content-Type" "application/json"
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just user -> do
                todoReq <- S.body :: S.ActionM BL.ByteString
                case decode todoReq of
                    Nothing -> do
                        S.status HTTP.status400
                        S.json $ object ["error" .= (fromString "Invalid JSON")]
                    Just decodedObj -> case extractTodoFields decodedObj of
                        Nothing -> do
                            S.status HTTP.status400
                            S.json $ object ["error" .= (fromString "Invalid JSON")]
                        Just (rawTitle, rawDesc) -> 
                            let title = fromMaybe "" (T.unpack <$> rawTitle)
                                description = fromMaybe "" (T.unpack <$> rawDesc)
                            in if null title || title == ""
                                then do
                                    S.status HTTP.status400
                                    S.json $ object ["error" .= (fromString "Title is required")]
                                else do
                                    newTodo <- liftIO $ createNewTodo state title description (userId user)
                                    S.status HTTP.status201
                                    S.json newTodo
    
    -- GET /todos/:id - protected
    S.get "/todos/:id" $ do
        S.setHeader "Content-Type" "application/json"
        todoIdText <- S.capture
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just authenticatedUser -> do
                let parsedId = readMaybe $ T.unpack todoIdText
                case parsedId of
                    Nothing -> do
                        S.status HTTP.status400
                        S.json $ object ["error" .= (fromString "Invalid ID")]
                    Just todoId' -> do
                        mTodo <- liftIO $ getTodoByIdAndUser state todoId' (userId authenticatedUser)
                        case mTodo of
                            Nothing -> do
                                S.status HTTP.status404
                                S.json $ object ["error" .= (fromString "Todo not found")]
                            Just todo -> S.json todo
    
    -- PUT /todos/:id - protected
    S.put "/todos/:id" $ do
        S.setHeader "Content-Type" "application/json"
        todoIdText <- S.capture
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just authenticatedUser -> do
                let parsedId = readMaybe $ T.unpack todoIdText
                case parsedId of
                    Nothing -> do
                        S.status HTTP.status400
                        S.json $ object ["error" .= (fromString "Invalid ID")]
                    Just todoId' -> do
                        todoExistsForUser <- liftIO $ doesTodoExistForUser state todoId' (userId authenticatedUser)
                        if not todoExistsForUser
                            then do
                                S.status HTTP.status404
                                S.json $ object ["error" .= (fromString "Todo not found")]
                            else do
                                updateData <- S.jsonData :: S.ActionM TodoUpdateRequest
                                
                                -- Validate if present and title is empty
                                case updateTitle updateData of
                                    Just title -> 
                                        if T.null title || title == ""
                                            then do
                                                S.status HTTP.status400
                                                S.json $ object ["error" .= (fromString "Title is required")]
                                            else return ()
                                    _ -> return ()
                                
                                updatedTodo <- liftIO $ updateTodoById state todoId' updateData
                                S.json updatedTodo
                
    -- DELETE /todos/:id - protected
    S.delete "/todos/:id" $ do
        S.setHeader "Content-Type" "application/json"
        todoIdText <- S.capture
        mAuthResult <- checkAuth state
        case mAuthResult of
            Nothing -> do
                S.status HTTP.status401
                S.json $ object ["error" .= (fromString "Authentication required")]
            Just authenticatedUser -> do
                let parsedId = readMaybe $ T.unpack todoIdText
                case parsedId of
                    Nothing -> do
                        S.status HTTP.status400
                        S.json $ object ["error" .= (fromString "Invalid ID")]
                    Just todoId' -> do
                        todoExistsForUser <- liftIO $ doesTodoExistForUser state todoId' (userId authenticatedUser)
                        if not todoExistsForUser
                            then do
                                S.status HTTP.status404
                                S.json $ object ["error" .= (fromString "Todo not found")]
                            else do
                                liftIO $ deleteTodoById state todoId'
                                S.status HTTP.status204 -- No content for delete

-- Helper function to check auth and get user
checkAuth :: AppState -> S.ActionM (Maybe User)
checkAuth state = do
  headers <- S.header "cookie"
  case headers of
    Nothing -> return Nothing
    Just cookieHdr -> 
      let pairs = parseCookieString (TE.decodeUtf8 $ BL.toStrict cookieHdr)
          mSessionId = lookup "session_id" pairs
      in case mSessionId of
           Nothing -> return Nothing
           Just sessionId -> liftIO $ atomically $ do
             sessMap <- readTVar (sessions state)
             case Map.lookup (T.unpack sessionId) sessMap of
               Nothing -> return Nothing
               Just userId' -> do
                 usersList <- readTVar (users state)
                 return $ fmap snd $ find (\(uid, _) -> uid == userId') usersList

-- Extract title and description from JSON object
extractTodoFields :: Value -> Maybe (Maybe T.Text, Maybe T.Text)
extractTodoFields (Object obj) = do
  mtitle <- case KeyMap.lookup "title" obj of
                 Just (Data.Aeson.String s) -> Just $ Just s
                 Just Null -> Just Nothing
                 Nothing -> Just Nothing
                 _ -> Nothing
  mdesc <- case KeyMap.lookup "description" obj of
                Just (Data.Aeson.String s) -> Just $ Just s
                Just Null -> Just Nothing
                Nothing -> Just Nothing
                Just _ -> Just $ Just ""
  return (mtitle >>= return, mdesc >>= return)    
extractTodoFields _ = Nothing

-- Cookie parsing - helper function
parseCookieString :: T.Text -> [(T.Text, T.Text)]
parseCookieString cookiesText = 
  mapMaybe parsePair $ T.splitOn (T.pack ";") cookiesText
  where
    parsePair pair = 
      let trimmed = T.strip pair
          parts = T.splitOn (T.pack "=") trimmed
      in if length parts >= 2
         then Just (T.strip (head parts), T.intercalate (T.pack "=") (tail parts))  -- Rejoin after first =
         else Nothing

-- Core functions for the app
registerUser :: AppState -> String -> String -> IO (Either String User)
registerUser state' usrNm pwd = atomically $ do
  usersList <- readTVar (users state')
  let allNames = map (username . snd) usersList
  
  -- Validation checks
  if not (validateUsername usrNm)
    then return $ Left "Invalid username"
    else if length pwd < 8
      then return $ Left "Password too short"
      else if usrNm `elem` allNames
        then return $ Left "Username already exists"
        else do
          newUserId <- readTVar (nextUserId state')
          let hashedPwd = hashPassword pwd
              newUser = User { userId = newUserId, username = usrNm, passwordHash = hashedPwd }
          
          modifyTVar (users state') ((newUserId, newUser) :)
          writeTVar (nextUserId state') (newUserId + 1)
          return $ Right newUser

authenticateUser :: AppState -> String -> String -> IO (Either String (User, SessionID))
authenticateUser state' usrNm pwd = do
  allUsers <- readTVarIO (users state')
  let maybeUser = find (\(_, u) -> username u == usrNm) allUsers
  case maybeUser of
    Nothing -> return $ Left "Invalid credentials"
    Just (_, user) -> 
      if passwordHash user /= hashPassword pwd
        then return $ Left "Invalid credentials"
        else do
          sessionId <- generateSessionId
          atomically $ modifyTVar (sessions state') (Map.insert sessionId (userId user))
          return $ Right (user, sessionId)

changeUserPassword :: AppState -> Int -> String -> String -> IO (Either String ())
changeUserPassword state' userId' oldPwd newPwd = atomically $ do
  usersList <- readTVar (users state')
  case find (\(uid, u) -> uid == userId') usersList of
    Nothing -> return $ Left "User not found"
    Just (origUserId, origUser) -> 
      if passwordHash origUser /= hashPassword oldPwd
        then return $ Left "Invalid credentials"
        else do
          let newUser = origUser { passwordHash = hashPassword newPwd }
          let others = filter (\(uid, _) -> uid /= userId') usersList
          writeTVar (users state') $ others ++ [(userId', newUser)]
          return $ Right ()

getUserTodos :: AppState -> Int -> IO [Todo]
getUserTodos state' userId' = do
  allTodos <- readTVarIO (todos state')
  return $ map_snd $ filter (\(_, t) -> ownerId t == userId') allTodos
  where map_snd l = map snd l

createNewTodo :: AppState -> String -> String -> Int -> IO Todo
createNewTodo state' title desc owner = do
  createdAtStr <- getISOString
  updatedAtStr <- getISOString
  todoId' <- atomically $ do
    nextId <- readTVar (nextTodoId state')
    writeTVar (nextTodoId state') (nextId + 1)
    return nextId
  
  let newTodo = Todo { 
        todoId = todoId', 
        todoTitle = title, 
        todoDescription = desc, 
        todoCompleted = False, 
        createdAt = createdAtStr, 
        updatedAt = updatedAtStr, 
        ownerId = owner 
      }
  
  atomically $ modifyTVar (todos state') ((todoId', newTodo) :)
  return newTodo

getTodoByIdAndUser :: AppState -> Int -> Int -> IO (Maybe Todo)
getTodoByIdAndUser state' todoId' userId' = do
  allTodos <- readTVarIO (todos state')
  let matchingTuple = find (\(_, t) -> todoId t == todoId' && ownerId t == userId') allTodos
  return $ fmap snd matchingTuple

doesTodoExistForUser :: AppState -> Int -> Int -> IO Bool
doesTodoExistForUser state' todoId' userId' = do
  mTodo <- getTodoByIdAndUser state' todoId' userId'
  return $ isJust mTodo

updateTodoById :: AppState -> Int -> TodoUpdateRequest -> IO Todo
updateTodoById state' todoId' updateData = do
  oldTodos <- readTVarIO (todos state')
  let maybeTodo = find (\(_, t) -> todoId t == todoId') oldTodos
  
  case maybeTodo of
    Nothing -> error "Todo not found"  -- Shouldn't happen due to validation
    Just (origId, oldTodo) -> do
      newUpdatedAt <- getISOString
      let updatedTodo = oldTodo
            { todoTitle = case updateTitle updateData of
                            Just t -> T.unpack t 
                            Nothing -> todoTitle oldTodo,
              todoDescription = case updateDescription updateData of
                                  Just d -> T.unpack d
                                  Nothing -> todoDescription oldTodo,
              todoCompleted = case updateCompleted updateData of
                                Just c -> c
                                Nothing -> todoCompleted oldTodo,
              updatedAt = newUpdatedAt
            }
      
      atomically $ do
        -- Remove old entry and add updated one
        let others = filter (\(id, _) -> id /= todoId') oldTodos
        writeTVar (todos state') $ others ++ [(todoId', updatedTodo)]
      
      return updatedTodo

deleteTodoById :: AppState -> Int -> IO ()
deleteTodoById state' todoId' = atomically $ do
  oldTodos <- readTVar (todos state')
  let filteredTodos = filter (\(_, t) -> todoId t /= todoId') oldTodos
  writeTVar (todos state') filteredTodos

removeSession :: AppState -> String -> IO ()
removeSession state' sessionId = 
  atomically $ modifyTVar (sessions state') (Map.delete sessionId)