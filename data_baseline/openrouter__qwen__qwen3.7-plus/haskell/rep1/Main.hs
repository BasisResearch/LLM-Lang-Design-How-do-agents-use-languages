{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO, atomically, modifyTVar)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Aeson as Aeson
import Data.Aeson (eitherDecode', object, (.=), (.:), (.:?), (.!=), FromJSON(..), ToJSON(..), withObject)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, fromJust, fromMaybe)
import Data.List (sortBy)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (utcToZonedTime, utc)
import qualified Data.UUID.V4 as UUID
import qualified Data.UUID as UUID
import Web.Scotty
import Network.HTTP.Types.Status (status200, status201, status204, status400, status401, status404, status409, status500)
import Text.Read (readMaybe)
import Data.Char (isAscii, isAlpha, isDigit)
import System.Environment (getArgs)

-- Global state
{-# NOINLINE globalState #-}
globalState :: TVar State
globalState = unsafePerformIO (newTVarIO initialState)

-- Data types
data User = User
  { uId :: Int
  , uUsername :: T.Text
  , uPassword :: T.Text
  }

data Todo = Todo
  { tId :: Int
  , tTitle :: T.Text
  , tDescription :: T.Text
  , tCompleted :: Bool
  , tCreatedAt :: T.Text
  , tUpdatedAt :: T.Text
  , tOwnerId :: Int
  }

data State = State
  { stNextUserId :: Int
  , stUsers :: Map.Map T.Text User
  , stUsersById :: Map.Map Int User
  , stNextTodoId :: Int
  , stTodos :: Map.Map Int Todo
  , stSessions :: Map.Map T.Text Int
  }

initialState :: State
initialState = State
  { stNextUserId = 1
  , stUsers = Map.empty
  , stUsersById = Map.empty
  , stNextTodoId = 1
  , stTodos = Map.empty
  , stSessions = Map.empty
  }

-- JSON Instances
data UserRegReq = UserRegReq { regUsername :: T.Text, regPassword :: T.Text }
instance FromJSON UserRegReq where
    parseJSON = withObject "UserRegReq" $ \v -> UserRegReq
        <$> v .: "username"
        <*> v .: "password"

data UserLoginReq = UserLoginReq { loginUsername :: T.Text, loginPassword :: T.Text }
instance FromJSON UserLoginReq where
    parseJSON = withObject "UserLoginReq" $ \v -> UserLoginReq
        <$> v .: "username"
        <*> v .: "password"

data UserRes = UserRes Int T.Text
instance ToJSON UserRes where
    toJSON (UserRes uid uname) = object ["id" .= uid, "username" .= uname]

data PasswordReq = PasswordReq { reqOldPassword :: T.Text, reqNewPassword :: T.Text }
instance FromJSON PasswordReq where
    parseJSON = withObject "PasswordReq" $ \v -> PasswordReq
        <$> v .: "old_password"
        <*> v .: "new_password"

data TodoReq = TodoReq { reqTitle :: T.Text, reqDesc :: T.Text }
instance FromJSON TodoReq where
    parseJSON = withObject "TodoReq" $ \v -> TodoReq
        <$> v .: "title"
        <*> v .:? "description" .!= ""

data TodoUpdateReq = TodoUpdateReq
    { updTitle :: Maybe T.Text
    , updDesc :: Maybe T.Text
    , updCompleted :: Maybe Bool
    }
instance FromJSON TodoUpdateReq where
    parseJSON = withObject "TodoUpdateReq" $ \v -> TodoUpdateReq
        <$> v .:? "title"
        <*> v .:? "description"
        <*> v .:? "completed"

data TodoRes = TodoRes
    { resId :: Int
    , resTitle :: T.Text
    , resDescription :: T.Text
    , resCompleted :: Bool
    , resCreatedAt :: T.Text
    , resUpdatedAt :: T.Text
    }
instance ToJSON TodoRes where
    toJSON (TodoRes tid title desc comp created updated) = object
        [ "id" .= tid
        , "title" .= title
        , "description" .= desc
        , "completed" .= comp
        , "created_at" .= created
        , "updated_at" .= updated
        ]

-- Helpers
isValidUsername :: T.Text -> Bool
isValidUsername t = len >= 3 && len <= 50 && T.all isValidChar t
  where
    len = T.length t
    isValidChar c = (isAscii c && isAlpha c) || isDigit c || c == '_'

generateUUID :: IO String
generateUUID = do
    uuid <- UUID.nextRandom
    return $ UUID.toString uuid

getCurrentTimeISO :: IO T.Text
getCurrentTimeISO = do
    now <- getCurrentTime
    let utcTime = utcToZonedTime utc now
    return $ T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" utcTime

withAuth :: (Int -> ActionM ()) -> ActionM ()
withAuth action = do
    mCookieHeader <- header "Cookie"
    let getSid hdr = do
            let splitCookie t = 
                    let (k, v) = LT.break (== '=') t
                    in (LT.strip k, LT.strip (LT.dropWhile (== '=') v))
            let cookiePairs = map splitCookie (LT.splitOn ";" hdr)
            return $ lookup "session_id" cookiePairs
    
    mUserId <- case mCookieHeader of
        Nothing -> return Nothing
        Just hdr -> do
            mSid <- getSid hdr
            case mSid of
                Nothing -> return Nothing
                Just sid -> do
                    state <- liftIO $ readTVarIO globalState
                    return $ Map.lookup (LT.toStrict sid) (stSessions state)
    
    case mUserId of
        Nothing -> do
            status status401
            json (object ["error" .= ("Authentication required" :: T.Text)])
        Just uid -> action uid

-- Application Routes
app :: ScottyM ()
app = do
    post "/register" $ do
        bodyData <- body
        case eitherDecode' bodyData of
            Left _ -> do
                status status400
                json (object ["error" .= ("Invalid request" :: T.Text)])
            Right r -> do
                let u = regUsername r
                let p = regPassword r
                if not (isValidUsername u)
                    then do
                        status status400
                        json (object ["error" .= ("Invalid username" :: T.Text)])
                    else if T.length p < 8
                        then do
                            status status400
                            json (object ["error" .= ("Password too short" :: T.Text)])
                        else do
                            state <- liftIO $ readTVarIO globalState
                            if Map.member u (stUsers state)
                                then do
                                    status status409
                                    json (object ["error" .= ("Username already exists" :: T.Text)])
                                else do
                                    let newId = stNextUserId state
                                    let newUser = User newId u p
                                    liftIO $ atomically $ modifyTVar globalState $ \s -> s
                                        { stNextUserId = newId + 1
                                        , stUsers = Map.insert u newUser (stUsers s)
                                        , stUsersById = Map.insert newId newUser (stUsersById s)
                                        }
                                    status status201
                                    json (UserRes newId u)

    post "/login" $ do
        bodyData <- body
        case eitherDecode' bodyData of
            Left _ -> do
                status status400
                json (object ["error" .= ("Invalid request" :: T.Text)])
            Right r -> do
                state <- liftIO $ readTVarIO globalState
                case Map.lookup (loginUsername r) (stUsers state) of
                    Nothing -> do
                        status status401
                        json (object ["error" .= ("Invalid credentials" :: T.Text)])
                    Just user ->
                        if uPassword user /= loginPassword r
                            then do
                                status status401
                                json (object ["error" .= ("Invalid credentials" :: T.Text)])
                            else do
                                sessionId <- liftIO generateUUID
                                liftIO $ atomically $ modifyTVar globalState $ \s -> s
                                    { stSessions = Map.insert (T.pack sessionId) (uId user) (stSessions s) }
                                setHeader "Set-Cookie" (LT.pack $ "session_id=" ++ sessionId ++ "; Path=/; HttpOnly")
                                status status200
                                json (UserRes (uId user) (uUsername user))

    post "/logout" $
        withAuth $ \_userId -> do
            mCookieHeader <- header "Cookie"
            case mCookieHeader of
                Nothing -> return ()
                Just hdr -> do
                    let splitCookie t = 
                            let (k, v) = LT.break (== '=') t
                            in (LT.strip k, LT.strip (LT.dropWhile (== '=') v))
                    let cookiePairs = map splitCookie (LT.splitOn ";" hdr)
                    case lookup "session_id" cookiePairs of
                        Nothing -> return ()
                        Just sid -> do
                            liftIO $ atomically $ modifyTVar globalState $ \s -> s
                                { stSessions = Map.delete (LT.toStrict sid) (stSessions s) }
            status status200
            json (Aeson.object [])

    get "/me" $
        withAuth $ \userId -> do
            state <- liftIO $ readTVarIO globalState
            case Map.lookup userId (stUsersById state) of
                Nothing -> do
                    status status500
                    json (object ["error" .= ("User not found" :: T.Text)])
                Just u -> do
                    status status200
                    json (UserRes (uId u) (uUsername u))

    put "/password" $
        withAuth $ \userId -> do
            bodyData <- body
            case eitherDecode' bodyData of
                Left _ -> do
                    status status400
                    json (object ["error" .= ("Invalid request" :: T.Text)])
                Right r -> do
                    state <- liftIO $ readTVarIO globalState
                    case Map.lookup userId (stUsersById state) of
                        Nothing -> do
                            status status500
                            json (object ["error" .= ("User not found" :: T.Text)])
                        Just user ->
                            if uPassword user /= reqOldPassword r
                                then do
                                    status status401
                                    json (object ["error" .= ("Invalid credentials" :: T.Text)])
                                else if T.length (reqNewPassword r) < 8
                                    then do
                                        status status400
                                        json (object ["error" .= ("Password too short" :: T.Text)])
                                    else do
                                        let updatedUser = user { uPassword = reqNewPassword r }
                                        liftIO $ atomically $ modifyTVar globalState $ \s -> s
                                            { stUsers = Map.insert (uUsername user) updatedUser (stUsers s)
                                            , stUsersById = Map.insert userId updatedUser (stUsersById s)
                                            }
                                        status status200
                                        json (Aeson.object [])

    get "/todos" $
        withAuth $ \userId -> do
            state <- liftIO $ readTVarIO globalState
            let todos = Map.elems (stTodos state)
            let userTodos = filter (\t -> tOwnerId t == userId) todos
            let sortedTodos = sortBy (\a b -> compare (tId a) (tId b)) userTodos
            let res = map (\t -> TodoRes (tId t) (tTitle t) (tDescription t) (tCompleted t) (tCreatedAt t) (tUpdatedAt t)) sortedTodos
            status status200
            json res

    post "/todos" $
        withAuth $ \userId -> do
            bodyData <- body
            case eitherDecode' bodyData of
                Left _ -> do
                    status status400
                    json (object ["error" .= ("Invalid request" :: T.Text)])
                Right r -> do
                    if T.null (reqTitle r)
                        then do
                            status status400
                            json (object ["error" .= ("Title is required" :: T.Text)])
                        else do
                            now <- liftIO getCurrentTimeISO
                            state <- liftIO $ readTVarIO globalState
                            let newId = stNextTodoId state
                            let newTodo = Todo newId (reqTitle r) (reqDesc r) False now now userId
                            liftIO $ atomically $ modifyTVar globalState $ \s -> s
                                { stNextTodoId = newId + 1
                                , stTodos = Map.insert newId newTodo (stTodos s)
                                }
                            status status201
                            json (TodoRes newId (reqTitle r) (reqDesc r) False now now)

    get "/todos/:id" $
        withAuth $ \userId -> do
            tidStr <- pathParam "id"
            case readMaybe (LT.unpack tidStr) of
                Nothing -> do
                    status status404
                    json (object ["error" .= ("Todo not found" :: T.Text)])
                Just tid -> do
                    state <- liftIO $ readTVarIO globalState
                    case Map.lookup tid (stTodos state) of
                        Nothing -> do
                            status status404
                            json (object ["error" .= ("Todo not found" :: T.Text)])
                        Just t ->
                            if tOwnerId t /= userId
                                then do
                                    status status404
                                    json (object ["error" .= ("Todo not found" :: T.Text)])
                                else do
                                    status status200
                                    json (TodoRes (tId t) (tTitle t) (tDescription t) (tCompleted t) (tCreatedAt t) (tUpdatedAt t))

    put "/todos/:id" $
        withAuth $ \userId -> do
            tidStr <- pathParam "id"
            case readMaybe (LT.unpack tidStr) of
                Nothing -> do
                    status status404
                    json (object ["error" .= ("Todo not found" :: T.Text)])
                Just tid -> do
                    state <- liftIO $ readTVarIO globalState
                    case Map.lookup tid (stTodos state) of
                        Nothing -> do
                            status status404
                            json (object ["error" .= ("Todo not found" :: T.Text)])
                        Just t ->
                            if tOwnerId t /= userId
                                then do
                                    status status404
                                    json (object ["error" .= ("Todo not found" :: T.Text)])
                                else do
                                    bodyData <- body
                                    case eitherDecode' bodyData of
                                        Left _ -> do
                                            status status400
                                            json (object ["error" .= ("Invalid request" :: T.Text)])
                                        Right r -> do
                                            if isJust (updTitle r) && T.null (fromJust (updTitle r))
                                                then do
                                                    status status400
                                                    json (object ["error" .= ("Title is required" :: T.Text)])
                                                else do
                                                    now <- liftIO getCurrentTimeISO
                                                    let newTitle = fromMaybe (tTitle t) (updTitle r)
                                                    let newDesc = fromMaybe (tDescription t) (updDesc r)
                                                    let newComp = fromMaybe (tCompleted t) (updCompleted r)
                                                    let updatedTodo = t { tTitle = newTitle, tDescription = newDesc, tCompleted = newComp, tUpdatedAt = now }
                                                    liftIO $ atomically $ modifyTVar globalState $ \s -> s
                                                        { stTodos = Map.insert tid updatedTodo (stTodos s) }
                                                    status status200
                                                    json (TodoRes (tId updatedTodo) (tTitle updatedTodo) (tDescription updatedTodo) (tCompleted updatedTodo) (tCreatedAt updatedTodo) (tUpdatedAt updatedTodo))

    delete "/todos/:id" $
        withAuth $ \userId -> do
            tidStr <- pathParam "id"
            case readMaybe (LT.unpack tidStr) of
                Nothing -> do
                    status status404
                    json (object ["error" .= ("Todo not found" :: T.Text)])
                Just tid -> do
                    state <- liftIO $ readTVarIO globalState
                    case Map.lookup tid (stTodos state) of
                        Nothing -> do
                            status status404
                            json (object ["error" .= ("Todo not found" :: T.Text)])
                        Just t ->
                            if tOwnerId t /= userId
                                then do
                                    status status404
                                    json (object ["error" .= ("Todo not found" :: T.Text)])
                                else do
                                    liftIO $ atomically $ modifyTVar globalState $ \s -> s
                                        { stTodos = Map.delete tid (stTodos s) }
                                    status status204

main :: IO ()
main = do
    args <- getArgs
    let port = case args of
                 ["--port", p] -> read p :: Int
                 _ -> 8080
    putStrLn $ "Starting server on port " ++ show port
    -- Force initialization of globalState
    _ <- readTVarIO globalState
    scotty port app
