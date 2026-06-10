{-# LANGUAGE OverloadedStrings #-}

import Web.Scotty 
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Aeson
import qualified Data.Map.Strict as Map 
import qualified Data.HashMap.Strict as HM
import qualified Data.Aeson.KeyMap as KM
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import Control.Monad.IO.Class
import Control.Concurrent.STM
import Control.Concurrent.STM.TMVar
import Data.Time
import Data.Char (isSpace)
import System.Environment (getArgs)
import qualified Data.Text.Lazy as TL

data User = User
  { userId :: Int
  , username :: T.Text
  , hashedPassword :: String
  } deriving (Show, Eq)

instance ToJSON User where
  toJSON u = object [ "id" .= userId u, "username" .= username u ]

data Todo = Todo
  { todoId :: Int
  , todoUserId :: Int
  , title :: T.Text
  , description :: T.Text
  , completed :: Bool
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON t = object
    [ "id" .= todoId t
    , "title" .= title t
    , "description" .= description t
    , "completed" .= completed t
    , "created_at" .= formatTimestamp (createdAt t)
    , "updated_at" .= formatTimestamp (updatedAt t)
   ]

data AppState = AppState
  { users :: TMVar (Map.Map Int User)
  , todos :: TMVar (Map.Map Int Todo)
  , sessions :: TMVar (Map.Map String Int)
  , nextUserId :: TMVar Int
  , nextTodoId :: TMVar Int
  }

formatTimestamp :: UTCTime -> T.Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

initAppState :: IO AppState
initAppState = do
  usersTVar <- newTMVarIO Map.empty
  todosTVar <- newTMVarIO Map.empty
  sessionsTVar <- newTMVarIO Map.empty
  nextUserIdTVar <- newTMVarIO 1
  nextTodoIdTVar <- newTMVarIO 1
  return AppState { users = usersTVar, todos = todosTVar, sessions = sessionsTVar, nextUserId = nextUserIdTVar, nextTodoId = nextTodoIdTVar }

getNextUserId :: AppState -> IO Int
getNextUserId state = atomically $ do
  currentId <- takeTMVar (nextUserId state)
  let newId = currentId + 1
  putTMVar (nextUserId state) newId
  return currentId

getNextTodoId :: AppState -> IO Int
getNextTodoId state = atomically $ do
  currentId <- takeTMVar (nextTodoId state)
  let newId = currentId + 1
  putTMVar (nextTodoId state) newId
  return currentId

simpleHash :: T.Text -> String
simpleHash = show . sum . map fromEnum . T.unpack

validateUsername :: T.Text -> Bool
validateUsername username =
  len >= 3 && len <= 50 && T.all isValidChar username
  where
    len = T.length username
    isValidChar c = (c >= 'a' && c <= 'z') || 
                     (c >= 'A' && c <= 'Z') || 
                     (c >= '0' && c <= '9') || 
                     c == '_'

validatePassword :: T.Text -> Bool
validatePassword password = T.length password >= 8

extractSessionIdFromHeaders :: [HTTP.Header] -> Maybe String
extractSessionIdFromHeaders headers = 
  case lookup "Cookie" headers of
    Nothing -> Nothing
    Just cookieBS -> 
      let cookieStr = TE.decodeUtf8 cookieBS
          pairs = map sanitizePair (T.split (== ';') cookieStr)
          sessionIdPair = findMaybe (\(key, val) -> if key == "session_id" then Just val else Nothing) pairs
      in sessionIdPair

sanitizePair :: T.Text -> (T.Text, String)
sanitizePair pair = 
  case T.break (== '=') pair of
    (key, rest) -> (T.strip key, if T.null rest then "" else tail . T.unpack $ T.strip rest)

findMaybe :: (a -> Maybe b) -> [a] -> Maybe b
findMaybe _ [] = Nothing
findMaybe f (x:xs) = case f x of
  Nothing -> findMaybe f xs
  Just result -> Just result

findUserByName :: AppState -> T.Text -> STM (Maybe User)
findUserByName state name = do
  usersMap <- readTMVar (users state)
  return $ foldl (\acc (uid, user) -> if username user == name then Just user else acc) Nothing (Map.toList usersMap)

findUserBySessionId :: AppState -> String -> STM (Maybe User)
findUserBySessionId state sessionId = do
  sessionsMap <- readTMVar (sessions state)
  usersMap <- readTMVar (users state)
  case Map.lookup sessionId sessionsMap of
    Nothing -> return Nothing
    Just userId -> return $ Map.lookup userId usersMap

authenticateUser :: AppState -> T.Text -> T.Text -> STM (Maybe User)
authenticateUser state username' password = do
  usersMap <- readTMVar (users state)
  let hashedInput = simpleHash password
  return $ foldl (\acc (_, user) -> if username user == username' && hashedPassword user == hashedInput then Just user else acc) Nothing (Map.toList usersMap)

data CreateUserRequest = CreateUserRequest
  { reqUsername :: T.Text
  , reqPassword :: T.Text
  } deriving (Show)

data LoginRequest = LoginRequest
  { loginUsername :: T.Text
  , loginPassword :: T.Text
  } deriving (Show)

data ChangePasswordRequest = ChangePasswordRequest
  { oldPassword :: T.Text
  , newPassword :: T.Text
  } deriving (Show)

data UpdateTodoRequest = UpdateTodoRequest
  { updateTitle :: Maybe T.Text
  , updateDescription :: Maybe T.Text
  , updateCompleted :: Maybe Bool
  } deriving (Show)

instance FromJSON CreateUserRequest where
  parseJSON = withObject "CreateUserRequest" $ \o -> CreateUserRequest
    <$> o .: "username"
    <*> o .: "password"

instance FromJSON LoginRequest where
  parseJSON = withObject "LoginRequest" $ \o -> LoginRequest
    <$> o .: "username"
    <*> o .: "password"

instance FromJSON ChangePasswordRequest where
  parseJSON = withObject "ChangePasswordRequest" $ \o -> ChangePasswordRequest
    <$> o .: "old_password"
    <*> o .: "new_password"

instance FromJSON UpdateTodoRequest where
  parseJSON = withObject "UpdateTodoRequest" $ \o -> UpdateTodoRequest
    <$> o .:? "title"
    <*> o .:? "description"
    <*> o .:? "completed"

requireAuth :: AppState -> (User -> ActionM ()) -> ActionM ()
requireAuth state handler = do
  headers <- request >>= \req -> return $ Wai.requestHeaders req
  mSessionId <- return $ extractSessionIdFromHeaders headers
  case mSessionId of
    Nothing -> authenticationFailure
    Just sessionId -> do
      mAuthUser <- liftIO $ atomically $ findUserBySessionId state sessionId
      case mAuthUser of
        Nothing -> authenticationFailure
        Just user -> handler user
  where
    authenticationFailure = do
      status HTTP.status401
      json $ object ["error" .= ("Authentication required" :: T.Text)]

generateSessionId :: IO String
generateSessionId = do
  time <- getCurrentTime
  return $ take 24 $ map (\c -> if c `elem` ['.', ':', '-', ' '] then '_' else c) $ show time

sortTodosById :: [Todo] -> [Todo]
sortTodosById [] = []
sortTodosById [x] = [x]
sortTodosById xs = mergeSortTodos xs
  where
    mergeSortTodos [] = []
    mergeSortTodos [x] = [x]
    mergeSortTodos ys = 
      let (left, right) = splitAt (length ys `div` 2) ys
      in mergeTodos (mergeSortTodos left) (mergeSortTodos right)
    
    mergeTodos [] rs = rs
    mergeTodos ls [] = ls
    mergeTodos (l:ls) (r:rs) = 
      if todoId l < todoId r
        then l : mergeTodos ls (r:rs)
        else r : mergeTodos (l:ls) rs

-- Create the individual route handlers to extract the path parameter correctly
todoApp :: AppState -> ScottyM ()
todoApp state = do
  -- Register
  post "/register" $ do
    CreateUserRequest uname pwd <- jsonData :: ActionM CreateUserRequest
    
    if not (validateUsername uname)
      then do
        status HTTP.status400
        json $ object ["error" .= ("Invalid username" :: T.Text)]
      else if not (validatePassword pwd)
        then do
          status HTTP.status400
          json $ object ["error" .= ("Password too short" :: T.Text)]
        else do
          existingUser <- liftIO $ atomically $ findUserByName state uname
          case existingUser of
            Just _ -> do
              status HTTP.status409
              json $ object ["error" .= ("Username already exists" :: T.Text)]
            Nothing -> do
              newUserId <- liftIO $ getNextUserId state
              let hashedPwd = simpleHash pwd
                  newUser = User newUserId uname hashedPwd
              
              liftIO $ atomically $ do
                usersMap <- readTMVar (users state)
                writeTMVar (users state) (Map.insert newUserId newUser usersMap)
              
              status HTTP.status201
              json newUser

  -- Login
  post "/login" $ do
    LoginRequest uname pwd <- jsonData :: ActionM LoginRequest
    
    authenticatedUser <- liftIO $ atomically $ authenticateUser state uname pwd
    case authenticatedUser of
      Nothing -> do
        status HTTP.status401
        json $ object ["error" .= ("Invalid credentials" :: T.Text)]
      Just user -> do
        sessionId <- liftIO generateSessionId
        liftIO $ atomically $ do
          sessionsMap <- readTMVar (sessions state)
          writeTMVar (sessions state) (Map.insert sessionId (userId user) sessionsMap)
        
        setHeader "Set-Cookie" $ TL.pack ("session_id=" ++ sessionId ++ "; Path=/; HttpOnly")
        status HTTP.status200
        json user

  -- Logout
  post "/logout" $ requireAuth state $ \_ -> do
    headers <- request >>= \req -> return $ Wai.requestHeaders req
    mSessionId <- return $ extractSessionIdFromHeaders headers
    case mSessionId of
      Just sessionId -> liftIO $ atomically $ do
        sessionsMap <- readTMVar (sessions state)
        writeTMVar (sessions state) (Map.delete sessionId sessionsMap)
      Nothing -> return ()
    
    status HTTP.status200
    json $ object []

  -- Get current user
  get "/me" $ requireAuth state $ \user -> do
    status HTTP.status200
    json user

  -- Change password
  put "/password" $ requireAuth state $ \currentUser -> do
    ChangePasswordRequest oldPwd newPwd <- jsonData :: ActionM ChangePasswordRequest
    
    if not (validatePassword newPwd)
      then do
        status HTTP.status400
        json $ object ["error" .= ("Password too short" :: T.Text)]
      else do
        let inputOldHash = simpleHash oldPwd
        if hashedPassword currentUser /= inputOldHash
          then do
            status HTTP.status401
            json $ object ["error" .= ("Invalid credentials" :: T.Text)]
          else do
            let updatedUser = currentUser { hashedPassword = simpleHash newPwd }
            liftIO $ atomically $ do
              usersMap <- readTMVar (users state)
              writeTMVar (users state) (Map.insert (userId currentUser) updatedUser usersMap)
            
            status HTTP.status200
            json $ object []

  -- Get todos
  get "/todos" $ requireAuth state $ \currentUser -> do
    allTodos <- liftIO $ atomically $ readTMVar (todos state)
    let userTodos = filter (\t -> todoUserId t == userId currentUser) (Map.elems allTodos)
        sortedTodos = sortTodosById userTodos
    status HTTP.status200
    json sortedTodos

  -- Create new todo
  post "/todos" $ requireAuth state $ \currentUser -> do
    rawJson <- body
    mParsed <- return $ eitherDecode rawJson
    case mParsed of
      Left _ -> do
        status HTTP.status400
        json $ object ["error" .= ("Invalid JSON" :: T.Text)]
      Right obj -> do
        let extractField objStr = case obj of
              Object o -> case KM.lookup objStr o of
                Just (String s) -> Just s
                _ -> Nothing
              _ -> Nothing
                          
        let maybeTitle = extractField "title"
        let maybeDescription = extractField "description"
                        
        case maybeTitle of
          Nothing -> do
            status HTTP.status400
            json $ object ["error" .= ("Title is required" :: T.Text)]
          Just titleStr -> do
            if T.null titleStr || T.all isSpace titleStr
              then do
                status HTTP.status400
                json $ object ["error" .= ("Title is required" :: T.Text)]
              else do
                newTodoId <- liftIO $ getNextTodoId state
                timestamp <- liftIO getCurrentTime
                
                let descStr = case maybeDescription of
                                Just d -> d
                                Nothing -> ""
                    newTodo = Todo 
                              { todoId = newTodoId
                              , todoUserId = userId currentUser
                              , title = titleStr
                              , description = descStr
                              , completed = False
                              , createdAt = timestamp
                              , updatedAt = timestamp
                              }
                
                liftIO $ atomically $ do
                  todosMap <- readTMVar (todos state)
                  writeTMVar (todos state) (Map.insert newTodoId newTodo todosMap)
                
                status HTTP.status201
                json newTodo

  -- Get specific todo - now with the ID as a path parameter  
  get "/todos/:id" $ requireAuth state $ \currentUser -> do
    pathInfo <- (request >>= return . Wai.pathInfo)
    let idSeg = last pathInfo
    case reads (T.unpack idSeg) of
      [(todoIdVal, "")] -> do
        allTodos <- liftIO $ atomically $ readTMVar (todos state)
        case Map.lookup todoIdVal allTodos of
          Nothing -> do
            status HTTP.status404
            json $ object ["error" .= ("Todo not found" :: T.Text)]
          Just todo -> 
            if todoUserId todo /= userId currentUser
              then do
                status HTTP.status404
                json $ object ["error" .= ("Todo not found" :: T.Text)]
              else do
                status HTTP.status200
                json todo
      _ -> do
        status HTTP.status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]

  -- Update specific todo
  put "/todos/:id" $ requireAuth state $ \currentUser -> do
    pathInfo <- (request >>= return . Wai.pathInfo)
    let idSeg = last pathInfo
    updateReq <- jsonData :: ActionM UpdateTodoRequest
    
    case reads (T.unpack idSeg) of
      [(todoIdVal, "")] -> do
        allTodos <- liftIO $ atomically $ readTMVar (todos state)
        case Map.lookup todoIdVal allTodos of
          Nothing -> do
            status HTTP.status404
            json $ object ["error" .= ("Todo not found" :: T.Text)]
          Just todo -> 
            if todoUserId todo /= userId currentUser
              then do
                status HTTP.status404
                json $ object ["error" .= ("Todo not found" :: T.Text)]
              else do
                case updateTitle updateReq of
                  Just newTitle -> 
                    if T.null newTitle || T.all isSpace newTitle
                      then do
                        status HTTP.status400
                        json $ object ["error" .= ("Title is required" :: T.Text)]
                      else return ()
                  Nothing -> return ()
                
                now <- liftIO getCurrentTime
                let updatedTodo = todo
                      { title = case updateTitle updateReq of
                                  Just t -> t
                                  Nothing -> title todo
                      , description = case updateDescription updateReq of
                                    Just d -> d 
                                    Nothing -> description todo
                      , completed = case updateCompleted updateReq of
                                  Just c -> c
                                  Nothing -> completed todo
                      , updatedAt = now
                      }
                
                liftIO $ atomically $ do
                  writeTMVar (todos state) (Map.insert todoIdVal updatedTodo allTodos)
                
                status HTTP.status200
                json updatedTodo
      _ -> do
        status HTTP.status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]

  -- Delete specific todo
  delete "/todos/:id" $ requireAuth state $ \currentUser -> do
    pathInfo <- (request >>= return . Wai.pathInfo)
    let idSeg = last pathInfo
    
    case reads (T.unpack idSeg) of
      [(todoIdVal, "")] -> do
        allTodos <- liftIO $ atomically $ readTMVar (todos state)
        case Map.lookup todoIdVal allTodos of
          Nothing -> do
            status HTTP.status404
            json $ object ["error" .= ("Todo not found" :: T.Text)]
          Just todo -> 
            if todoUserId todo /= userId currentUser
              then do
                status HTTP.status404 
                json $ object ["error" .= ("Todo not found" :: T.Text)]
              else do
                liftIO $ atomically $ do
                  updatedTodos <- readTMVar (todos state)
                  writeTMVar (todos state) (Map.delete todoIdVal updatedTodos)
                
                status HTTP.status204  -- No content
                return ()
      _ -> do
        status HTTP.status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]

main :: IO ()
main = do
  args <- getArgs
  let port = if length args >= 2 && args !! 0 == "--port"
              then read (args !! 1) :: Int
              else 3000
  
  state <- initAppState
  putStrLn $ "Starting server on port " ++ show port
  scotty port (todoApp state)