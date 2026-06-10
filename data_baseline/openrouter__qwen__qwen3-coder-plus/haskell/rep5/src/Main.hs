{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad (void, unless, when)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Char8 as B8
import qualified Data.Map.Strict as Map
import Data.Time (getCurrentTime, formatTime, defaultTimeLocale)
import Network.HTTP.Types.Status (Status, status400, status401, status404, status409, status200, status201, status204)
import Network.Wai (Middleware)
import Web.Scotty
import System.Environment (getArgs)
import Text.Read (readMaybe)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID  
import Data.Maybe (fromMaybe, isJust)
import Web.Cookie (parseCookies, parseCookiesText)  
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import qualified Data.Text.Encoding as TE
import qualified Data.Text as T

-- | Represents a user in our system
data User = User 
  { userId :: Int
  , username :: String
  , passwordHash :: String  -- Simplified storage, should use proper hashing in production
  } deriving (Show, Eq)

-- | Represents a Todo item
data Todo = Todo 
  { todoId :: Int
  , title :: String
  , description :: String
  , completed :: Bool
  , createdAt :: String
  , updatedAt :: String
  , ownerId :: Int  -- Reference to the user who owns this todo
  } deriving (Show, Eq)

-- | User creation form
data RegisterForm = RegisterForm
  { regUsername :: String
  , regPassword :: String
  } deriving (Show, Eq)

instance FromJSON RegisterForm where
    parseJSON = withObject "RegisterForm" $ \o -> do
        u <- o .: "username"
        p <- o .: "password"
        return $ RegisterForm u p

-- | Login form
data LoginForm = LoginForm
  { logUsername :: String
  , logPassword :: String
  } deriving (Show, Eq)

instance FromJSON LoginForm where
    parseJSON = withObject "LoginForm" $ \o -> do
        u <- o .: "username"
        p <- o .: "password"
        return $ LoginForm u p

-- | Change password form
data PasswordForm = PasswordForm
  { oldPassword :: String
  , newPassword :: String
  } deriving (Show, Eq)

instance FromJSON PasswordForm where
    parseJSON = withObject "PasswordForm" $ \o -> do
        old <- o .: "old_password"
        new <- o .: "new_password"
        return $ PasswordForm old new

-- | Todo creation/update form (partial updates allowed)
data TodoForm = TodoForm
  { ftTitle :: Maybe String
  , ftDescription :: Maybe String
  , ftCompleted :: Maybe Bool
  } deriving (Show, Eq)

instance FromJSON TodoForm where
    parseJSON = withObject "TodoForm" $ \o -> do
        t <- o .:? "title"
        d <- o .:? "description"
        c <- o .:? "completed"
        return $ TodoForm t d c

instance ToJSON User where
    toJSON u = object [ "id" .= userId u, "username" .= username u ]

instance ToJSON Todo where
    toJSON t = object 
        [ "id" .= todoId t
        , "title" .= title t
        , "description" .= description t
        , "completed" .= completed t
        , "created_at" .= createdAt t
        , "updated_at" .= updatedAt t
        ]

-- Type variables for our in-memory stores
type Users = Map.Map Int User  
type Todos = Map.Map Int Todo
type Sessions = Map.Map UUID Int  -- Maps session_id to user_id
type State = TVar (Users, Todos, Sessions, Int, Int)

-- | Generate a current ISO 8601 timestamp string  
getTimestamp :: IO String
getTimestamp = do
    now <- getCurrentTime
    return $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now

-- | Check if a username is valid (alphanumeric + underscore, 3-50 chars)
isValidUsername :: String -> Bool
isValidUsername s 
  | length s < 3 || length s > 50 = False
  | otherwise = all isValidChar s
  where
    isValidChar c = c `elem` ['a'..'z'] || c `elem` ['A'..'Z'] || c `elem` ['0'..'9'] || c == '_'

-- | Main entry point
main :: IO ()
main = do
    args <- getArgs
    let portArg = case filter (isPrefixOf "--port=") args of
                  [] -> "8080"  -- default port 
                  [arg] -> drop 7 arg  -- Drop "--port="
                  _ -> error "Multiple --port options provided"
    let port = fromMaybe 8080 (readMaybe portArg)
    
    state <- newTVarIO (Map.empty, Map.empty, Map.empty, 1, 1)
    
    scotty port $ do
        -- POST /register - Create a new user
        post "/register" $ do
            setHeader "Content-Type" "application/json"
            formData <- jsonData @RegisterForm
            
            -- Validate input
            unless (isValidUsername $ regUsername formData) $
                sendError status400 "Invalid username"
                
            unless (length (regPassword formData) >= 8) $
                sendError status400 "Password too short"
            
            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO state
            when (any (\u -> username u == regUsername formData) (Map.elems users)) $
                sendError status409 "Username already exists"
                
            let newUser = User 
                    { userId = nextUserId
                    , username = regUsername formData
                    , passwordHash = regPassword formData -- Again, simplified - use proper hashing in real app
                    }
            let newUsers = Map.insert nextUserId newUser users
            liftIO $ atomically $ writeTVar state (newUsers, todos, sessions, nextUserId + 1, nextTodoId)
            
            status status201
            json newUser
        
        -- POST /login - Authenticate and create session
        post "/login" $ do
            setHeader "Content-Type" "application/json"
            formData <- jsonData @LoginForm
            
            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO state
            let matchingUsers = filter (\u -> username u == logUsername formData) (Map.elems users)
            
            case matchingUsers of
                [] -> sendError status401 "Invalid credentials"
                (user:_) -> 
                    if passwordHash user == logPassword formData
                       then do
                         -- Generate a new session
                         sessionId <- liftIO UUID.nextRandom
                         let newSessions = Map.insert sessionId (userId user) sessions
                         liftIO $ atomically $ writeTVar state (users, todos, newSessions, nextUserId, nextTodoId)
                         
                         -- Set the session cookie
                         let sessionIdStr = UUID.toString sessionId
                         let cookieStr = "session_id=" ++ sessionIdStr ++ "; Path=/; HttpOnly"
                         setHeader "Set-Cookie" (B8.pack cookieStr)
                         status status200
                         json user
                       else sendError status401 "Invalid credentials"
        
        -- POST /logout - Invalidate session
        post "/logout" $ do
            _ <- authenticate state
            mCookieBs <- header "Cookie"
            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO state
            case mCookieBs of
                Nothing -> do
                    setHeader "Content-Type" "application/json"
                    json $ object ["error" .= ("Authentication required" :: String)]
                    status status401
                Just cookieBytes -> do
                    -- Process cookieBytes directly as lazy ByteString  
                    let cookieText = TE.decodeUtf8 $ LBS.toStrict cookieBytes
                    let cookiePairs = parseCookiesNameValuePair $ T.unpack cookieText
                    case lookup "session_id" cookiePairs of
                        Nothing -> do
                            setHeader "Content-Type" "application/json"
                            json $ object ["error" .= ("Authentication required" :: String)]
                            status status401
                        Just sessionIdBS -> do
                            let sessionIdStr = B8.unpack sessionIdBS
                            case UUID.fromString sessionIdStr of
                                Nothing -> do
                                    setHeader "Content-Type" "application/json"
                                    json $ object ["error" .= ("Authentication required" :: String)]
                                    status status401
                                Just sessionId -> do
                                    let newSessions = Map.delete sessionId sessions
                                    liftIO $ atomically $ writeTVar state (users, todos, newSessions, nextUserId, nextTodoId)
                                    setHeader "Content-Type" "application/json"
                                    json $ object []
        
        -- GET /me - Get currently authenticated user
        get "/me" $ do
            userId <- authenticate state
            (users, _, _, _, _) <- liftIO $ readTVarIO state
            case Map.lookup userId users of
                Nothing -> do
                    setHeader "Content-Type" "application/json"
                    json $ object ["error" .= ("Authentication required" :: String)]
                    status status401
                Just user -> json user
        
        -- PUT /password - Change password of authenticated user
        put "/password" $ do
            setHeader "Content-Type" "application/json"
            userId <- authenticate state
            formData <- jsonData @PasswordForm
            
            unless (length (newPassword formData) >= 8) $
                sendError status400 "Password too short"
                
            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO state
            case Map.lookup userId users of
                Nothing -> sendError status401 "Authentication required"  -- Shouldn't happen if auth worked
                Just user ->
                    if passwordHash user == oldPassword formData
                       then do
                        let updatedUser = user { passwordHash = newPassword formData }
                        let newUsers = Map.insert userId updatedUser users
                        liftIO $ atomically $ writeTVar state (newUsers, todos, sessions, nextUserId, nextTodoId)
                        json $ object []
                       else sendError status401 "Invalid credentials"
        
        -- GET /todos - List all todos for authenticated user
        get "/todos" $ do
            setHeader "Content-Type" "application/json"  
            userId <- authenticate state
            (_, todos, _, _, _) <- liftIO $ readTVarIO state
            -- Filter todos that belong to this user and sort by ID
            let userTodos = filter (\t -> ownerId t == userId) $ map snd $ Map.toAscList todos
            json userTodos
        
        -- POST /todos - Create a new todo
        post "/todos" $ do
            setHeader "Content-Type" "application/json"
            userId <- authenticate state
            todoData <- jsonData @TodoForm
            
            unless (maybe False (not . null) (ftTitle todoData)) $
              sendError status400 "Title is required"
            
            currTime <- liftIO getTimestamp
            
            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO state
            
            let newTodo = Todo 
                    { todoId = nextTodoId
                    , title = fromMaybe "" (ftTitle todoData)
                    , description = fromMaybe "" (ftDescription todoData)
                    , completed = fromMaybe False (ftCompleted todoData)
                    , createdAt = currTime
                    , updatedAt = currTime
                    , ownerId = userId
                    }
            
            let newTodos = Map.insert nextTodoId newTodo todos
            liftIO $ atomically $ writeTVar state (users, newTodos, sessions, nextUserId + 1, nextTodoId + 1)
            
            status status201
            json newTodo
        
        -- GET /todos/:id - Get a specific todo
        get "/todos/:tid" $ do
            setHeader "Content-Type" "application/json"
            userId <- authenticate state
            tidStr <- param "tid"
            tid <- case readMaybe tidStr of
                Nothing -> do
                    setHeader "Content-Type" "application/json"
                    json $ object ["error" .= ("Invalid ID" :: String)]
                    status status400
                    finish
                Just idValue -> return idValue
            
            (_, todos, _, _, _) <- liftIO $ readTVarIO state
            case Map.lookup tid todos of
                Nothing -> sendError status404 "Todo not found"
                Just todo -> 
                    if ownerId todo /= userId
                        then sendError status404 "Todo not found"  -- Important: don't expose that other user's todo exists
                        else json todo
        
        -- PUT /todos/:id - Update a specific todo (partial update)
        put "/todos/:tid" $ do
            setHeader "Content-Type" "application/json"
            userId <- authenticate state
            tidStr <- param "tid"
            todoData <- jsonData @TodoForm
            
            tid <- case readMaybe tidStr of
                Nothing -> do
                    setHeader "Content-Type" "application/json"
                    json $ object ["error" .= ("Invalid ID" :: String)] 
                    status status400
                    finish
                Just idValue -> return idValue
            
            -- Validate the title if provided
            when (isJust (ftTitle todoData) && maybe True null (ftTitle todoData)) $
              sendError status400 "Title is required"
            
            currTime <- liftIO getTimestamp
            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO state
            
            case Map.lookup tid todos of
                Nothing -> sendError status404 "Todo not found"
                Just oldTodo ->
                    if ownerId oldTodo /= userId
                        then sendError status404 "Todo not found"
                        else do
                         let updatedTitle = fromMaybe (title oldTodo) (ftTitle todoData)
                         let updatedDesc = fromMaybe (description oldTodo) (ftDescription todoData) 
                         let updatedCompleted = fromMaybe (completed oldTodo) (ftCompleted todoData)
                         let updatedTodo = oldTodo
                                 { title = updatedTitle
                                 , description = updatedDesc
                                 , completed = updatedCompleted
                                 , updatedAt = currTime
                                 }
                         let newTodos = Map.insert tid updatedTodo todos
                         liftIO $ atomically $ writeTVar state (users, newTodos, sessions, nextUserId, nextTodoId)
                         json updatedTodo
         
        -- DELETE /todos/:id - Delete a specific todo  
        delete "/todos/:tid" $ do
            userId <- authenticate state
            tidStr <- param "tid"
            tid <- case readMaybe tidStr of
                Nothing -> do
                    setHeader "Content-Type" "application/json"
                    json $ object ["error" .= ("Invalid ID" :: String)]
                    status status400
                    finish
                Just idValue -> return idValue
            
            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO state
            case Map.lookup tid todos of
                Nothing -> sendError status404 "Todo not found"
                Just todo ->
                    if ownerId todo /= userId
                        then sendError status404 "Todo not found"
                        else do
                         -- Remove the todo
                         let newTodos = Map.delete tid todos
                         liftIO $ atomically $ writeTVar state (users, newTodos, sessions, nextUserId, nextTodoId)
                         status status204


-- Main authenticate function
authenticate :: State -> ActionM Int
authenticate stateTVar = do
    mCookieHdr <- header "Cookie"
    case mCookieHdr of
        Nothing -> do
            setHeader "Content-Type" "application/json"
            json $ object ["error" .= ("Authentication required" :: String)]
            status status401
            finish
        Just cookieBytes -> do
            -- Decode the cookie header properly
            let cookieText = TE.decodeUtf8 $ LBS.toStrict cookieBytes
            let cookiePairs = parseCookiesNameValuePair $ T.unpack cookieText
            case lookup "session_id" cookiePairs of
                Nothing -> do
                    setHeader "Content-Type" "application/json"
                    json $ object ["error" .= ("Authentication required" :: String)]
                    status status401
                    finish
                Just sessionIdBS -> 
                    let sessionIdStr = B8.unpack sessionIdBS in
                    case UUID.fromString sessionIdStr of
                        Nothing -> do
                            setHeader "Content-Type" "application/json"
                            json $ object ["error" .= ("Authentication required" :: String)]
                            status status401
                            finish
                        Just sessionId -> do
                            (users, todos, sessions, nextUserId, nextTodoId) <- liftIO $ readTVarIO stateTVar
                            case Map.lookup sessionId sessions of
                                Nothing -> do
                                    setHeader "Content-Type" "application/json"
                                    json $ object ["error" .= ("Authentication required" :: String)]
                                    status status401
                                    finish
                                Just userId -> return userId

-- Helper to parse cookie pairs in format "key1=value1; key2=value2"
parseCookiesNameValuePair :: String -> [(String, B8.ByteString)]
parseCookiesNameValuePair str = 
    map parsePair $ splitOn ';' str
  where
    parsePair s = 
        let (k, v) = span (/= '=') s
            cleanK = trim k
            rest = drop 1 v -- remove the '='
            cleanV = B8.pack (trim rest)
        in (cleanK, cleanV)

splitOn :: Char -> String -> [String]
splitOn c s = foldr f [[]] s
  where
    f x [] = [[x]]
    f x (ys:yss) | x == c = []:(ys:yss)
                 | otherwise = (x:ys):yss

trim :: String -> String                      
trim s = dropWhile (== ' ') (dropWhileEnd (== ' ') s)
  where
    dropWhileEnd p = reverse . dropWhile p . reverse

-- Error response helper
sendError :: Status -> String -> ActionM ()
sendError status_val msg = do
    setHeader "Content-Type" "application/json"
    json $ object ["error" .= msg]
    status status_val

-- Helper function to check if a string starts with a prefix
isPrefixOf :: String -> String -> Bool
isPrefixOf [] _ = True
isPrefixOf (x:xs) (y:ys) = x == y && isPrefixOf xs ys
isPrefixOf _ [] = False