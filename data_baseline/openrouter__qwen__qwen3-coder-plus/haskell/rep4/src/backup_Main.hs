{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Web.Scotty
import Data.Aeson (encode, decode, toJSON, object, (.=), FromJSON(parseJSON), ToJSON(toJSON))
import qualified Data.Text.Lazy as T
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.Map as M
import qualified Data.Digest.Pure.MD5 as MD5
import qualified Data.ByteString.Char8 as C
import qualified Data.Time as Time
import qualified Data.UUID.V4 as UUID
import Data.IORef
import Data.List (find, sortBy)
import Data.Function (on)
import System.Environment (getArgs)

-- Define types
newtype ErrorMsg = ErrorMsg String
instance ToJSON ErrorMsg where
    toJSON (ErrorMsg msg) = object ["error" .= msg]

data User = User { userId :: Int, username :: String } deriving (Show)
instance ToJSON User where
    toJSON (User uid uname) = object ["id" .= uid, "username" .= uname]
instance FromJSON User where
    parseJSON = withObject "User" $ \o -> User <$> o .: "id" <*> o .: "username"

data Todo = Todo 
    { todoId :: Int
    , todoUserId :: Int
    , title :: String
    , description :: String
    , completed :: Bool
    , createdAt :: String
    , updatedAt :: String }
    deriving (Show)
instance ToJSON Todo where
    toJSON (Todo tid uid t d c ct ut) = object
        [ "id" .= tid
        , "title" .= t
        , "description" .= d
        , "completed" .= c
        , "created_at" .= ct
        , "updated_at" .= ut ]

data RegisterRequest = RegisterRequest String String deriving (Show)
instance FromJSON RegisterRequest where
    parseJSON = withObject "RegisterRequest" $ \o -> RegisterRequest 
        <$> o .: "username"
        <*> o .: "password"

data LoginRequest = LoginRequest String String deriving (Show)
instance FromJSON LoginRequest where
    parseJSON = withObject "LoginRequest" $ \o -> LoginRequest
        <$> o .: "username"
        <*> o .: "password"

data PasswordChangeRequest = PasswordChangeRequest String String deriving (Show)
instance FromJSON PasswordChangeRequest where
    parseJSON = withObject "PasswordChangeRequest" $ \o -> PasswordChangeRequest
        <$> o .: "old_password"
        <*> o .: "new_password"

data TodoCreateRequest = TodoCreateRequest String String deriving (Show)
instance FromJSON TodoCreateRequest where
    parseJSON = withObject "TodoCreateRequest" $ \o -> TodoCreateRequest
        <$> o .: "title"
        <*> o .:? "description" .!= ""

data TodoUpdateRequest = TodoUpdateRequest (Maybe String) (Maybe String) (Maybe Bool) deriving (Show)
instance FromJSON TodoUpdateRequest where
    parseJSON = withObject "TodoUpdateRequest" $ \o -> TodoUpdateRequest 
        <$> o .:? "title"
        <*> o .:? "description"
        <*> o .:? "completed"

withObject :: String -> (T.Object -> T.Parser a) -> T.Value -> T.Parser a
withObject msg f = T.withObject msg f

-- State
data AppState = AppState 
    { usersDB :: IORef (M.Map Int (User, String))  -- User Id -> (User, hashedPassword)
    , todosDB :: IORef (M.Map Int Todo)
    , sessionsDB :: IORef (M.Map String Int)  -- SessionID -> UserId
    , userIdCounter :: IORef Int
    , todoIdCounter :: IORef Int
    }

initState :: IO AppState
initState = do
    usersVar <- newIORef M.empty
    todosVar <- newIORef M.empty
    sessionsVar <- newIORef M.empty
    userIdVar <- newIORef 1
    todoIdVar <- newIORef 1
    return AppState 
        { usersDB = usersVar
        , todosDB = todosVar
        , sessionsDB = sessionsVar
        , userIdCounter = userIdVar
        , todoIdCounter = todoIdVar
        }

-- Helpers
hashPass :: String -> String
hashPass pwd = UTF8.toString $ MD5.md5 $ C.pack pwd

nowStr :: IO String
nowStr = do 
    t <- Time.getCurrentTime
    return $ Time.formatTime Time.defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t

-- Generate user and todo IDs
newUserId :: AppState -> IO Int
newUserId appState = atomicModifyIORef (userIdCounter appState) $ \n -> (n+1, n)

newTodoId :: AppState -> IO Int
newTodoId appState = atomicModifyIORef (todoIdCounter appState) $ \n -> (n+1, n)

-- Extract session ID from cookie
extractSid :: String -> Maybe String
extractSid cs = 
    let pairs = map (drop 1 . break (== '=')) (splitOn ';' cs) 
        sidPair = find ((== "session_id") . fst) pairs
    in fmap snd sidPair
  where
    break :: (a -> Bool) -> [a] -> ([a], [a])
    break p xs = go xs []
      where
        go [] acc = (reverse acc, [])
        go (x:xs) acc | p x = (reverse acc, x:xs)
                      | otherwise = go xs (x:acc)
    
    splitOn :: Char -> String -> [String]
    splitOn c s = go s []
      where
        go [] acc = reverse ("" : acc)
        go (x:xs) [] | x == c = go xs [""]
                     | otherwise = go xs [[x]]
        go (x:xs) (h:t) | x == c = go xs ("" : h : t)
                        | otherwise = go xs ((x:h) : t)

authenticate :: AppState -> ActionM Int
authenticate appState = do
    mCookie <- header "Cookie"
    case mCookie of
        Nothing -> err401
        Just cookieBS -> case extractSid (C.unpack cookieBS) of
            Nothing -> err401
            Just sid -> do
                sessions <- liftIO $ readIORef (sessionsDB appState)
                case M.lookup sid sessions of
                    Nothing -> err401
                    Just uid -> return uid
  where
    err401 = do
        status $ status401
        json $ ErrorMsg "Authentication required"
        finish

-- Main
main :: IO ()
main = do
    args <- getArgs
    let port = case getPortArg args of
                   Just p -> read p
                   Nothing -> 3000
    state <- initState
    scotty port $ runApp state

getPortArg :: [String] -> Maybe String
getPortArg [] = Nothing
getPortArg ("--port":p:_) = Just p
getPortArg (_:rest) = getPortArg rest

runApp :: AppState -> ScottyM ()
runApp state = do
    post "/register" $ do
        r <- jsonData @RegisterRequest
        let (uname, pwd) = case r of RegisterRequest u p -> (u, p)
        if length uname < 3 || length uname > 50 || not (all isValidUsernameChar uname)
            then do
                status $ status400
                json $ ErrorMsg "Invalid username"
            else if length pwd < 8
                then do
                    status $ status400
                    json $ ErrorMsg "Password too short"
                else do
                    users <- liftIO $ readIORef (usersDB state)
                    if any (\(_, (usr, _)) -> username usr == uname) (M.toList users)
                        then do
                            status $ status409
                            json $ ErrorMsg "Username already exists"
                        else do
                            let hashedPwd = hashPass pwd
                            newUid <- liftIO $ newUserId state
                            let newUser = User newUid uname
                            liftIO $ modifyIORef (usersDB state) (M.insert newUid (newUser, hashedPwd))
                            status $ status201
                            json newUser
    
    post "/login" $ do
        r <- jsonData @LoginRequest
        let (uname, pwd) = case r of LoginRequest u p -> (u, p)
        users <- liftIO $ readIORef (usersDB state)
        let possibleUser = headMaybe [ (uid, pwdHash) | (uid, (usr, pwdHash)) <- M.toList users, username usr == uname ]
        case possibleUser of
            Nothing -> do
                status $ status401
                json $ ErrorMsg "Invalid credentials"
            Just (_, storedHash) -> do
                if hashPass pwd == storedHash
                    then do
                        -- Create session
                        newUUID <- liftIO UUID.nextRandom
                        let sessionStr = show newUUID
                        liftIO $ modifyIORef (sessionsDB state) (M.insert sessionStr (userId (fst (M.elemAt 0 users))))
                        -- Set-cookie header with session id
                        setHeader "Set-Cookie" ("session_id=" ++ sessionStr ++ "; Path=/; HttpOnly")
                        uids <- liftIO $ readIORef (usersDB state)
                        let foundUser = case M.filter (\(usr,_) -> username usr == uname) uids of
                                            ms | M.null ms -> User (-1) ""
                                               | otherwise -> (fst . head . M.elems $ ms)
                        status $ status200
                        json foundUser
                    else do
                        status $ status401
                        json $ ErrorMsg "Invalid credentials"
    
    post "/logout" $ do
        uid <- authenticate state
        mCookie <- header "Cookie"
        case mCookie of
            Just cookieBS -> case extractSid (C.unpack cookieBS) of
                Just sid -> liftIO $ modifyIORef (sessionsDB state) (M.delete sid)
                Nothing -> return ()
            Nothing -> return ()
        json $ object []
    
    get "/me" $ do
        uid <- authenticate state
        users <- liftIO $ readIORef (usersDB state)
        case M.lookup uid users of
            Nothing -> do
                status $ status500
                json $ ErrorMsg "Server error"
            Just (usr, _) -> json usr
    
    put "/password" $ do
        uid <- authenticate state
        r <- jsonData @PasswordChangeRequest
        let (oldP, newP) = case r of PasswordChangeRequest op np -> (op, np)
        if length newP < 8
            then do
                status $ status400
                json $ ErrorMsg "Password too short"
            else do
                users <- liftIO $ readIORef (usersDB state)
                case M.lookup uid users of
                    Nothing -> do
                        status $ status401
                        json $ ErrorMsg "Invalid credentials"
                    Just (usr, storedHash) -> do
                        if hashPass oldP == storedHash
                            then do
                                let newHash = hashPass newP
                                liftIO $ modifyIORef (usersDB state) (M.insert uid (usr, newHash))
                                json $ object []
                            else do
                                status $ status401
                                json $ ErrorMsg "Invalid credentials"
    
    get "/todos" $ do
        uid <- authenticate state
        todos <- liftIO $ readIORef (todosDB state)
        let userTodos = [t | t <- M.elems todos, todoUserId t == uid]
            sortedTodos = sortBy (compare `on` todoId) userTodos
        json sortedTodos
    
    post "/todos" $ do
        uid <- authenticate state
        r <- jsonData @TodoCreateRequest
        let (title, desc) = case r of TodoCreateRequest t d -> (t, d)
        if null title || all (== ' ') title
            then do
                status $ status400
                json $ ErrorMsg "Title is required"
            else do
                tid <- liftIO $ newTodoId state
                timeStr <- liftIO nowStr
                let newTodo = Todo tid uid title desc False timeStr timeStr
                liftIO $ modifyIORef (todosDB state) (M.insert tid newTodo)
                status $ status201
                json newTodo

    get "/todos/:id" $ do
        uid <- authenticate state
        tid <- param "id"
        todos <- liftIO $ readIORef (todosDB state)
        case M.lookup tid todos of
            Nothing -> do
                status $ status404
                json $ ErrorMsg "Todo not found"
            Just todo ->
                if todoUserId todo == uid
                    then json todo
                    else do
                        status $ status404
                        json $ ErrorMsg "Todo not found"

    put "/todos/:id" $ do
        uid <- authenticate state
        tid <- param "id" 
        todos <- liftIO $ readIORef (todosDB state)
        case M.lookup tid todos of
            Nothing -> do
                status $ status404
                json $ ErrorMsg "Todo not found"
            Just oldTodo ->
                if todoUserId oldTodo == uid
                    then do
                        reqBody <- body
                        case decode reqBody of
                            Nothing -> do
                                status $ status400
                                json $ ErrorMsg "Bad request"
                            Just (TodoUpdateRequest mTitle mDesc mComp) -> do
                                -- Validate title if provided
                                case mTitle of
                                    Just t | null t || all (== ' ') t -> do
                                        status $ status400
                                        json $ ErrorMsg "Title is required"
                                    _ -> do
                                        let updated = oldTodo
                                                  { title = case mTitle of
                                                              Just t -> t
                                                              Nothing -> title oldTodo,
                                                    description = case mDesc of
                                                                    Just d -> d
                                                                    Nothing -> description oldTodo,
                                                    completed = case mComp of
                                                                  Just c -> c
                                                                  Nothing -> completed oldTodo,
                                                    updatedAt <- liftIO nowStr }
                                        liftIO $ modifyIORef (todosDB state) (M.insert tid updated)
                                        json updated
                    else do
                        status $ status404
                        json $ ErrorMsg "Todo not found"
    
    delete "/todos/:id" $ do
        uid <- authenticate state  
        tid <- param "id"
        todos <- liftIO $ readIORef (todosDB state)
        case M.lookup tid todos of
            Nothing -> do
                status $ status404
                json $ ErrorMsg "Todo not found"
            Just todo ->
                if todoUserId todo == uid
                    then do
                        liftIO $ modifyIORef (todosDB state) (M.delete tid)
                        status $ status204
                    else do
                        status $ status404
                        json $ ErrorMsg "Todo not found"

isValidUsernameChar :: Char -> Bool
isValidUsernameChar c = c `elem` ('_':['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'])

headMaybe :: [a] -> Maybe a
headMaybe [] = Nothing
headMaybe (x:_) = Just x