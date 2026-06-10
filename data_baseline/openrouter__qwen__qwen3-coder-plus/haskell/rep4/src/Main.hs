{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Web.Scotty
import qualified Network.HTTP.Types.Status as HTTPStatus
import qualified Data.Aeson as Aeson
import qualified Data.Text as T
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
data ErrorMsg = ErrorMsg String
errorMsg :: String -> Aeson.Value
errorMsg msg = Aeson.object ["error" .= msg]

data User = User { userId :: Int, username :: String } deriving (Show)
userToValue :: User -> Aeson.Value
userToValue (User uid uname) = Aeson.object ["id" .= uid, "username" .= uname]

userFromValue :: Aeson.Value -> Either String User
userFromValue = Aeson.parseJSON $ \o -> User <$> o Aeson..: "id" <*> o Aeson..: "username"

data Todo = Todo 
    { todoId :: Int
    , todoUserId :: Int
    , title :: String
    , description :: String
    , completed :: Bool
    , createdAt :: String
    , updatedAt :: String }
    deriving (Show)
todoToValue :: Todo -> Aeson.Value
todoToValue (Todo tid uid t d c ct ut) = Aeson.object
    [ "id" .= tid
    , "title" .= t
    , "description" .= d
    , "completed" .= c
    , "created_at" .= ct
    , "updated_at" .= ut ]

registerRequestFromValue :: Aeson.Value -> Either String (String, String)  -- (username, password)
registerRequestFromValue = Aeson.parseJSON $ \o -> (,) <$> o Aeson..: "username" <*> o Aeson..: "password"

loginRequestFromValue :: Aeson.Value -> Either String (String, String)  -- (username, password)
loginRequestFromValue = Aeson.parseJSON $ \o -> (,) <$> o Aeson..: "username" <*> o Aeson..: "password"

passwordChangeRequestFromValue :: Aeson.Value -> Either String (String, String)  -- (oldpassword, newpassword)
passwordChangeRequestFromValue = Aeson.parseJSON $ \o -> (,) <$> o Aeson..: "old_password" <*> o Aeson..: "new_password"

todoCreateRequestFromValue :: Aeson.Value -> Either String (String, String)  -- (title, description)
todoCreateRequestFromValue = Aeson.parseJSON $ \o -> (,) <$> o Aeson..: "title" <*> o Aeson..:? "description" Aeson..!= ""

todoUpdateRequestFromValue :: Aeson.Value -> Either String (Maybe String, Maybe String, Maybe Bool)  -- (title, description, completed)
todoUpdateRequestFromValue = Aeson.parseJSON $ \o -> (,,) <$> 
    o Aeson..:? "title" <*> 
    o Aeson..:? "description" <*> 
    o Aeson..:? "completed"

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
    let pairs = map (dropWhile (== ' ') . drop 1) $ filter ("session_id=" `isPrefixOf`) $ splitOn ';' cs
    in case pairs of
        [] -> Nothing
        (sessionId:_) -> Just sessionId
  where
    isPrefixOf :: String -> String -> Bool
    isPrefixOf pre str = take (length pre) str == pre
    splitOn :: Char -> String -> [String]
    splitOn c s = go s []
      where
        go [] acc = reverse [acc]
        go (x:xs) acc | x == c = acc : go xs []
                      | otherwise = go xs (acc ++ [x])

authenticate :: AppState -> ActionM Int
authenticate appState = do
    mCookie <- header "Cookie"
    case mCookie of
        Nothing -> unauthorizedError
        Just cookieBS -> case extractSid (C.unpack cookieBS) of
            Nothing -> unauthorizedError
            Just sid -> do
                sessions <- liftIO $ readIORef (sessionsDB appState)
                case M.lookup sid sessions of
                    Nothing -> unauthorizedError
                    Just uid -> return uid
  where
    unauthorizedError = do
        status HTTPStatus.status401
        json $ errorMsg "Authentication required"
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
        bodyValue <- jsonData
        case registerRequestFromValue bodyValue of
            Left _ -> do
                status HTTPStatus.status400
                json $ errorMsg "Invalid request"
            Right (uname, pwd) -> do
                if length uname < 3 || length uname > 50 || not (all isValidUsernameChar uname)
                    then do
                        status HTTPStatus.status400
                        json $ errorMsg "Invalid username"
                    else if length pwd < 8
                        then do
                            status HTTPStatus.status400
                            json $ errorMsg "Password too short"
                        else do
                            users <- liftIO $ readIORef (usersDB state)
                            if any (\(_, (usr, _)) -> username usr == uname) (M.toList users)
                                then do
                                    status HTTPStatus.status409
                                    json $ errorMsg "Username already exists"
                                else do
                                    let hashedPwd = hashPass pwd
                                    newUid <- liftIO $ newUserId state
                                    let newUser = User newUid uname
                                    liftIO $ modifyIORef (usersDB state) (M.insert newUid (newUser, hashedPwd))
                                    status HTTPStatus.status201
                                    json $ userToValue newUser
    
    post "/login" $ do
        bodyValue <- jsonData
        case loginRequestFromValue bodyValue of
            Left _ -> do
                status HTTPStatus.status400
                json $ errorMsg "Invalid request"
            Right (uname, pwd) -> do
                users <- liftIO $ readIORef (usersDB state)
                let possibleUser = headMaybe [ (uid, pwdHash) | (uid, (usr, pwdHash)) <- M.toList users, username usr == uname ]
                case possibleUser of
                    Nothing -> do
                        status HTTPStatus.status401
                        json $ errorMsg "Invalid credentials"
                    Just (_, storedHash) -> do
                        if hashPass pwd == storedHash
                            then do
                                -- Create session
                                newUUID <- liftIO UUID.nextRandom
                                let sessionStr = show newUUID
                                uid <- liftIO $ do
                                    let users = M.filter (\(usr,_) -> username usr == uname) =<< M.toList <$> readIORef (usersDB state)
                                    return $ userId $ fst $ head $ M.elems users
                                
                                liftIO $ modifyIORef (sessionsDB state) (M.insert sessionStr uid)
                                
                                setHeader "Set-Cookie" (C.pack $ "session_id=" ++ sessionStr ++ "; Path=/; HttpOnly")
                                let foundUser = head [usr | (usr, _) <- M.elems users, username usr == uname]
                                status HTTPStatus.status200
                                json $ userToValue foundUser
                            else do
                                status HTTPStatus.status401
                                json $ errorMsg "Invalid credentials"
    
    post "/logout" $ do
        uid <- authenticate state
        mCookie <- header "Cookie"
        case mCookie of
            Just cookieBS -> case extractSid (C.unpack cookieBS) of
                Just sid -> liftIO $ modifyIORef (sessionsDB state) (M.delete sid)
                Nothing -> return ()
            Nothing -> return ()
        json $ Aeson.object []
    
    get "/me" $ do
        uid <- authenticate state
        users <- liftIO $ readIORef (usersDB state)
        case M.lookup uid users of
            Nothing -> do
                status HTTPStatus.status500
                json $ errorMsg "Server error"
            Just (usr, _) -> json $ userToValue usr
    
    put "/password" $ do
        uid <- authenticate state
        bodyValue <- jsonData
        case passwordChangeRequestFromValue bodyValue of
            Left _ -> do
                status HTTPStatus.status400
                json $ errorMsg "Invalid request"
            Right (oldP, newP) -> do
                if length newP < 8
                    then do
                        status HTTPStatus.status400
                        json $ errorMsg "Password too short"
                    else do
                        users <- liftIO $ readIORef (usersDB state)
                        case M.lookup uid users of
                            Nothing -> do
                                status HTTPStatus.status401
                                json $ errorMsg "Invalid credentials"
                            Just (usr, storedHash) -> do
                                if hashPass oldP == storedHash
                                    then do
                                        let newHash = hashPass newP
                                        liftIO $ modifyIORef (usersDB state) (M.insert uid (usr, newHash))
                                        json $ Aeson.object []
                                    else do
                                        status HTTPStatus.status401
                                        json $ errorMsg "Invalid credentials"
    
    get "/todos" $ do
        uid <- authenticate state
        todos <- liftIO $ readIORef (todosDB state)
        let userTodos = [t | t <- M.elems todos, todoUserId t == uid]
            sortedTodos = sortBy (compare `on` todoId) userTodos
        json $ Aeson.toJSON (map todoToValue sortedTodos)
    
    post "/todos" $ do
        uid <- authenticate state
        bodyValue <- jsonData
        case todoCreateRequestFromValue bodyValue of
            Left _ -> do
                status HTTPStatus.status400
                json $ errorMsg "Invalid request"
            Right (title', desc) -> do
                if null title' || all (== ' ') title'
                    then do
                        status HTTPStatus.status400
                        json $ errorMsg "Title is required"
                    else do
                        tid <- liftIO $ newTodoId state
                        timeStr <- liftIO nowStr
                        let newTodo = Todo tid uid title' desc False timeStr timeStr
                        liftIO $ modifyIORef (todosDB state) (M.insert tid newTodo)
                        status HTTPStatus.status201
                        json $ todoToValue newTodo

    get "/todos/:id" $ do
        uid <- authenticate state
        tidString <- param "id"
        let tid = read (C.unpack tidString)
        todos <- liftIO $ readIORef (todosDB state)
        case M.lookup tid todos of
            Nothing -> do
                status HTTPStatus.status404
                json $ errorMsg "Todo not found"
            Just todo ->
                if todoUserId todo == uid
                    then json $ todoToValue todo
                    else do
                        status HTTPStatus.status404
                        json $ errorMsg "Todo not found"

    put "/todos/:id" $ do
        uid <- authenticate state
        tidString <- param "id" 
        let tid = read (C.unpack tidString)
        todos <- liftIO $ readIORef (todosDB state)
        case M.lookup tid todos of
            Nothing -> do
                status HTTPStatus.status404
                json $ errorMsg "Todo not found"
            Just oldTodo ->
                if todoUserId oldTodo == uid
                    then do
                        reqBody <- body
                        case todoUpdateRequestFromValue reqBody of
                            Left _ -> do
                                status HTTPStatus.status400
                                json $ errorMsg "Bad request"
                            Right (mTitle, mDesc, mComp) -> do
                                -- Validate title if provided
                                case mTitle of
                                    Just t | null t || all (== ' ') t -> do
                                        status HTTPStatus.status400
                                        json $ errorMsg "Title is required"
                                    _ -> do
                                        timeStr <- liftIO nowStr
                                        let updated = oldTodo {
                                            title = case mTitle of
                                                        Just t -> t
                                                        Nothing -> title oldTodo,
                                            description = case mDesc of
                                                            Just d -> d
                                                            Nothing -> description oldTodo,
                                            completed = case mComp of
                                                          Just c -> c
                                                          Nothing -> completed oldTodo,
                                            updatedAt = timeStr }
                                        liftIO $ modifyIORef (todosDB state) (M.insert tid updated)
                                        json $ todoToValue updated
                    else do
                        status HTTPStatus.status404
                        json $ errorMsg "Todo not found"
    
    delete "/todos/:id" $ do
        uid <- authenticate state  
        tidString <- param "id"
        let tid = read (C.unpack tidString)
        todos <- liftIO $ readIORef (todosDB state)
        case M.lookup tid todos of
            Nothing -> do
                status HTTPStatus.status404
                json $ errorMsg "Todo not found"
            Just todo ->
                if todoUserId todo == uid
                    then do
                        liftIO $ modifyIORef (todosDB state) (M.delete tid)
                        status HTTPStatus.status204
                    else do
                        status HTTPStatus.status404
                        json $ errorMsg "Todo not found"

isValidUsernameChar :: Char -> Bool
isValidUsernameChar c = c `elem` ('_':['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'])

headMaybe :: [a] -> Maybe a
headMaybe [] = Nothing
headMaybe (x:_) = Just x