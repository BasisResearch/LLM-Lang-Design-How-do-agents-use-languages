{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImportQualifiedPost #-}

import Web.Scotty
import Control.Monad.IO.Class (liftIO)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap 
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Map.Strict as Map
import System.Random (randomRIO)
import Data.Time
import Data.List hiding (delete)
import Network.HTTP.Types as HTTP
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Control.Concurrent.MVar
import Data.Ord
import Options.Applicative hiding (param)
import Control.Monad (when, unless)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)

-- Data Types
data User = User 
  { userId :: Int
  , username :: String 
  } deriving (Show, Eq)

instance ToJSON User where
  toJSON u = object 
    [ "id" .= userId u
    , "username" .= username u 
    ]

data Todo = Todo 
  { todoId :: Int
  , todoUserId :: Int  -- Owner of the todo
  , title :: String
  , description :: String
  , completed :: Bool
  , createdAt :: String
  , updatedAt :: String
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON t = object 
    [ "id" .= todoId t
    , "title" .= title t
    , "description" .= description t
    , "completed" .= completed t
    , "created_at" .= createdAt t
    , "updated_at" .= updatedAt t
    ]

data AppState = AppState 
  { users :: Map.Map Int User
  , nextUserId :: Int
  , passwords :: Map.Map Int String  -- userId -> plain text password
  , todos :: Map.Map Int Todo
  , nextTodoId :: Int
  , sessions :: Map.Map String Int  -- sessionId -> userId
  } deriving (Show)

emptyState :: AppState
emptyState = AppState 
  { users = Map.empty
  , nextUserId = 1
  , passwords = Map.empty
  , todos = Map.empty
  , nextTodoId = 1
  , sessions = Map.empty
  }

-- Helper to get current time in ISO 8601 format
getCurrentTimeFormatted :: IO String
getCurrentTimeFormatted = do
  now <- getCurrentTime
  return $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (utcToLocalTime (hoursToTimeZone 0) now)

-- Custom createSession function
createSession2 :: AppState -> Int -> IO (AppState, String)
createSession2 state userId = do
  sessionId <- UUID.toString <$> UUID.nextRandom
  let newState = state { sessions = Map.insert sessionId userId (sessions state) }
  return (newState, sessionId)

-- Validate session ID
validateSession :: Map.Map String Int -> String -> Maybe Int
validateSession sessions sessionId = Map.lookup sessionId sessions

-- Generate response with error
sendError :: String -> ActionM ()
sendError msg = json $ object ["error" .= msg]

-- Check if username is valid (3-50 chars, alphanumeric + underscore)
isValidUsername :: String -> Bool
isValidUsername s = length s >= 3 && length s <= 50 && all isValidChar s
  where 
    isValidChar c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'

-- Convert T.Text to Key
textToKey :: T.Text -> Key.Key
textToKey = Key.fromString . T.unpack

-- Extract string field from JSON using Aeson
extractStrField :: Value -> T.Text -> Maybe String
extractStrField (Object o) field = KeyMap.lookup (textToKey field) o >>= \val -> case val of
  String s -> Just $ T.unpack s
  _ -> Nothing
extractStrField _ _ = Nothing

extractBoolField :: Value -> T.Text -> Maybe Bool
extractBoolField (Object o) field = KeyMap.lookup (textToKey field) o >>= \val -> case val of
  Bool b -> Just b
  _ -> Nothing
extractBoolField _ _ = Nothing

-- Parse cookies from a String cookie header
parseCookies :: String -> [(String, String)]
parseCookies cookieHdr = 
  let pairs = map trim (splitOn ';' cookieHdr) 
      keyValPairs = map parsePair pairs
  in filter (\(k,_) -> not (null k)) keyValPairs 
  where
    parsePair pair = 
      case break (== '=') pair of
        (k, '=':v) -> (trim k, trim v)
        (k, "") -> (trim k, "")
        _ -> ("", pair)  -- Invalid format so return empty key
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse

splitOn :: Char -> String -> [String]
splitOn delim s = case dropWhile (== delim) s of
                   "" -> []
                   s' -> w : splitOn delim s''
                     where (w, s'') = break (== delim) s'

-- Helper to sort todos by ID ascending
sortByTodoIdAsc :: [Todo] -> [Todo]
sortByTodoIdAsc = sortBy (comparing todoId)

data Args = Args { port :: Int } deriving (Show)

argsParser :: Parser Args
argsParser = Args <$> option auto (long "port" <> metavar "PORT" <> help "Port to listen on")

main :: IO ()
main = do
  -- Command line options
  Args p <- execParser (info (argsParser <**> helper) 
                        (fullDesc <> progDesc "Run todo app server"))
  
  -- Initialize the app state in an MVar
  appStateRef <- newMVar emptyState
  
  scotty p $ do  -- Use the parsed port
    -- Middleware to set content type to json for all responses
    middleware $ \request respond -> do
      -- Create a new response to set header on
      respond request

    -- Set content type header in all responses
    addHeader "Content-Type" "application/json"
    
    -- Custom handler to get session cookie from each request
    let
      -- Function to parse session ID from cookie header
      getSessionId :: ActionM (Maybe String)
      getSessionId = do
        mCookieHeader <- Web.Scotty.header "Cookie" -- Use disambiguated version
        case mCookieHeader of
          Nothing -> return Nothing
          Just cookieHeaderValue -> 
            let cookieHeaderText = TL.unpack cookieHeaderValue -- convert TL.Text to String
            in do
              let cookies = parseCookies cookieHeaderText
                  sessionId = lookup "session_id" cookies 
              return sessionId

      -- Get current user ID based on session cookie
      requireAuth :: (Int -> ActionM ()) -> ActionM ()
      requireAuth action = do
        mSessionId <- getSessionId
        mAppSt <- liftIO $ readMVar appStateRef
        let appState = mAppSt  -- Since we initialize to newMVar, this should give us AppState
        
        case mSessionId >>= (\sid -> Map.lookup sid (sessions appState)) of  -- Fix the validation
          Nothing -> do
            status HTTP.status401
            sendError "Authentication required"
          Just userId -> do
            action userId
    
    -- Register route
    post "/register" $ do
      body <- jsonData :: ActionM Value
      let mUsername = extractStrField body "username"
      let mPassword = extractStrField body "password"
      
      case (mUsername, mPassword) of
        (Nothing, _) -> do
          status HTTP.status400
          sendError "Invalid username"
        (_, Nothing) -> do
          status HTTP.status400
          sendError "Password too short"
        (Just usernameStr, Just passwordStr) -> do
          unless (isValidUsername usernameStr) $ do
            status HTTP.status400
            sendError "Invalid username"
          
          mAppSt <- liftIO $ readMVar appStateRef
          let appState = mAppSt
          
          let existingUser = find (\u -> username u == usernameStr) (Map.elems (users appState))
          when (isJust existingUser) $ do
            status HTTP.status409
            sendError "Username already exists"
          
          when (length passwordStr < 8) $ do
            status HTTP.status400
            sendError "Password too short"
          
          -- Create new user
          let newUserId = nextUserId appState
          let newUser = User newUserId usernameStr
          let newPasswords = Map.insert newUserId passwordStr (passwords appState)
          let newUsers = Map.insert newUserId newUser (users appState)
          
          liftIO $ modifyMVar_ appStateRef $ \s ->
            return $ s { users = newUsers, 
                         passwords = newPasswords, 
                         nextUserId = nextUserId s + 1 }
          
          status HTTP.status201
          json newUser
    
    -- Login route
    post "/login" $ do
      body <- jsonData :: ActionM Value
      let mUsername = extractStrField body "username"
      let mPassword = extractStrField body "password"
      
      case (mUsername, mPassword) of
        (_, Nothing) -> do
          status HTTP.status400
          sendError "Missing password"
        (Nothing, _) -> do
          status HTTP.status400
          sendError "Missing username"
        (Just usernameStr, Just passwordStr) -> do
          mAppSt <- liftIO $ readMVar appStateRef
          let appState = mAppSt
          
          -- Find user by username
          let usersList = Map.toList (users appState)
          let matchingUser = find (\(_, u) -> username u == usernameStr) usersList
          case matchingUser of
            Nothing -> do
              status HTTP.status401
              sendError "Invalid credentials"
            Just (userIdVal, _) -> do
              let actualPassword = Map.findWithDefault "" userIdVal (passwords appState)
              if actualPassword /= passwordStr 
                then do
                  status HTTP.status401
                  sendError "Invalid credentials"
                else do
                  (newAppState, sessionId) <- liftIO $ createSession2 appState userIdVal
                  liftIO $ modifyMVar_ appStateRef (\_ -> return newAppState)
                  
                  -- Set cookie in response
                  setHeader "Set-Cookie" (TL.pack $ "session_id=" ++ sessionId ++ "; Path=/; HttpOnly")
                      
                  let user = fromMaybe (User (-1) "") (Map.lookup userIdVal (users newAppState))
                  json user
    
    -- Logout route
    post "/logout" $ requireAuth $ \_ -> do
      mSessionId <- getSessionId
      mAppSt <- liftIO $ readMVar appStateRef
      let appState = mAppSt
      
      case mSessionId of
        Just sessionId -> do
          let newSessions = Map.delete sessionId (sessions appState)
          liftIO $ modifyMVar_ appStateRef $ \s -> return $ s { sessions = newSessions }
          status status200
          json $ object []
        Nothing -> do
          status HTTP.status401
          sendError "Authentication required"
    
    -- GET /me route
    get "/me" $ requireAuth $ \userId -> do
      mAppSt <- liftIO $ readMVar appStateRef
      let appState = mAppSt
      let user = fromMaybe (User (-1) "") (Map.lookup userId (users appState))
      json user
    
    -- PUT /password route
    put "/password" $ requireAuth $ \userId -> do
      body <- jsonData :: ActionM Value
      let mOldPassword = extractStrField body "old_password"
      let mNewPassword = extractStrField body "new_password"
      
      case (mOldPassword, mNewPassword) of
        (Nothing, _) -> do
          status HTTP.status400
          sendError "Missing old password"
        (_, Nothing) -> do
          status HTTP.status400
          sendError "Missing new password"
        (Just oldPass, Just newPass) -> do
          mAppSt <- liftIO $ readMVar appStateRef
          let appState = mAppSt
          let actualOldPassword = Map.findWithDefault "" userId (passwords appState)
          
          if actualOldPassword /= oldPass
            then do
              status HTTP.status401
              sendError "Invalid credentials"
            else when (length newPass < 8) $ do
              status HTTP.status400
              sendError "Password too short"
          
          when (length newPass >= 8) $ do
            -- Only update if old password matches
            unless (actualOldPassword /= oldPass) $ do
              -- Update password
              let newPasswords = Map.insert userId newPass (passwords appState)
              liftIO $ modifyMVar_ appStateRef $ \s -> return $ s { passwords = newPasswords }
              
              status status200
              json $ object []
    
    -- GET /todos route
    get "/todos" $ requireAuth $ \userId -> do
      mAppSt <- liftIO $ readMVar appStateRef
      let appState = mAppSt
      
      let userTodos = filter (\todo -> todoUserId todo == userId) 
                      (Map.elems (todos appState))
      json (sortByTodoIdAsc userTodos)
    
    -- POST /todos route
    post "/todos" $ requireAuth $ \userId -> do
      body <- jsonData :: ActionM Value
      let mTitle = extractStrField body "title"
      let mDescriptionRaw = extractStrField body "description"
      let mDescription = fromMaybe "" mDescriptionRaw
      
      case mTitle of
        Nothing -> do
          status HTTP.status400
          sendError "Title is required"
        Just titleStr -> do
          if null titleStr
            then do
              status HTTP.status400
              sendError "Title is required"
            else do
              mAppSt <- liftIO $ readMVar appStateRef
              let appState = mAppSt
              currentTime <- liftIO getCurrentTimeFormatted
              
              let newTodoId = nextTodoId appState
              let newTodo = Todo newTodoId userId titleStr mDescription False currentTime currentTime 
              let newTodos = Map.insert newTodoId newTodo (todos appState)
              
              liftIO $ modifyMVar_ appStateRef $ \s -> 
                return $ s { todos = newTodos, 
                             nextTodoId = nextTodoId s + 1 }
              
              status HTTP.status201
              json newTodo
    
    -- GET /todos/:id route
    get "/todos/:id" $ do  -- Use Scotty's built-in path parameter capturing
      todoId <- param "id" :: ActionM Int  -- Scotty converts to Int directly
        
      requireAuth $ \userId -> do
        mAppSt <- liftIO $ readMVar appStateRef
        let appState = mAppSt
        case Map.lookup todoId (todos appState) of
          Nothing -> do
            status HTTP.status404
            sendError "Todo not found"
          Just todo -> 
            if todoUserId todo /= userId
              then do
                status HTTP.status404
                sendError "Todo not found"
              else
                json todo

    -- PUT /todos/:id route
    put "/todos/:id" $ do  -- Use Scotty's built-in path parameter capturing
      todoId <- param "id" :: ActionM Int  -- Scotty converts to Int directly
      
      requireAuth $ \userId -> do
        mAppSt <- liftIO $ readMVar appStateRef
        let appState = mAppSt
        
        existingTodo <- case Map.lookup todoId (todos appState) of
          Nothing -> do
            status HTTP.status404
            sendError "Todo not found"
            empty
          Just existingTodo -> 
            if todoUserId existingTodo /= userId
              then do
                status HTTP.status404
                sendError "Todo not found"
                empty
              else pure existingTodo
        
        body <- jsonData :: ActionM Value
        let mTitle = extractStrField body "title"
        let mDescription = extractStrField body "description"
        let mCompleted = extractBoolField body "completed"
        
        -- Validate title if present
        if isJust mTitle && maybe False null mTitle
          then do
            status HTTP.status400
            sendError "Title is required"
          else do
            -- Update the todo
            currentTime <- liftIO getCurrentTimeFormatted
            let newTitle = fromMaybe (title existingTodo) mTitle
            let newDescription = fromMaybe (description existingTodo) mDescription
            let newCompleted = fromMaybe (completed existingTodo) mCompleted
            let updatedTodo = existingTodo 
                  { title = newTitle
                  , description = newDescription
                  , completed = newCompleted
                  , updatedAt = currentTime
                  }
            
            liftIO $ modifyMVar_ appStateRef $ \s -> 
              return $ s { todos = Map.insert todoId updatedTodo (todos s) }
            
            json updatedTodo

    -- DELETE /todos/:id route
    Web.Scotty.delete "/todos/:id" $ do  -- Disambiguate delete function
      todoId <- param "id" :: ActionM Int  -- Scotty converts to Int directly
        
      requireAuth $ \userId -> do
        mAppSt <- liftIO $ readMVar appStateRef
        let appState = mAppSt
        case Map.lookup todoId (todos appState) of
          Nothing -> do
            status HTTP.status404
            sendError "Todo not found"
          Just todo -> 
            if todoUserId todo /= userId
              then do
                status HTTP.status404
                sendError "Todo not found"
              else do
                let newTodos = Map.delete todoId (todos appState)
                liftIO $ modifyMVar_ appStateRef $ \s -> return $ s { todos = newTodos }
                status status204  -- Don't send body in 204