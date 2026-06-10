{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lib (startServer) where

import Web.Scotty
import Network.HTTP.Types
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.Aeson
import Data.Time
import Data.UUID (UUID)
import qualified Data.UUID as UUID  
import qualified Data.UUID.V4 as UUID
import Data.Time.Format.ISO8601 (iso8601Show)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe, isNothing, isJust)
import Control.Monad (join)
import Data.List (find, dropWhile)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map
import Data.IORef
import Data.Text.Read (decimal)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseMaybe, Parser)
import Control.Applicative ((<|>))

-- Data Types
data User = User 
  { userId :: Int
  , username :: T.Text
  , userPassword :: T.Text  -- In real app, this would be securely hashed
  } deriving (Eq, Show)

data Todo = Todo 
  { todoId :: Int
  , todoTitle :: T.Text
  , todoDescription :: T.Text
  , todoCompleted :: Bool
  , createdAt :: String
  , updatedAt :: String
  , todoOwnerId :: Int  -- Reference to user ID
  } deriving (Eq, Show)

-- Custom instances for FromJSON/ToJSON to handle timestamps
instance ToJSON User where
  toJSON (User uid uname _) = object [ "id" .= uid, "username" .= uname ]

instance ToJSON Todo where
  toJSON t = object [ "id" .= todoId t
                    , "title" .= todoTitle t
                    , "description" .= todoDescription t
                    , "completed" .= todoCompleted t
                    , "created_at" .= createdAt t
                    , "updated_at" .= updatedAt t
                    ]

-- For testing - simple string hashing (not secure for production!)
hashPassword :: T.Text -> T.Text
hashPassword p = T.pack $ show $ foldl (\acc c -> acc * 31 + fromEnum c) 0 (T.unpack p)

-- Generate a new timestamp string
nowUTC :: IO String  
nowUTC = do
  utctime <- getCurrentTime
  return $ iso8601Show utctime

-- Helper functions
splitOn :: Char -> String -> [String]
splitOn delim str = foldr f [[]] str
  where f c l@(x:xs) | c == delim = []:l
                     | otherwise = (c:x):xs

startServer :: Int -> IO ()
startServer port = do
  -- Initialize global state refs
  usersRef <- newIORef HM.empty
  todosRef <- newIORef []
  sessionsRef <- newIORef Map.empty
  userIdCounterRef <- newIORef 1
  todoIdCounterRef <- newIORef 1

  putStrLn $ "Starting server on port " ++ show port

  scotty port $ do
    -- Helper functions that interact with state  
    let getUserId = atomicModifyIORef userIdCounterRef $ \counter -> (counter + 1, counter)
    let getTodoId = atomicModifyIORef todoIdCounterRef $ \counter -> (counter + 1, counter)
    
    let addSession userId = do
          sessionId <- liftIO UUID.nextRandom
          sessions <- liftIO $ readIORef sessionsRef
          liftIO $ writeIORef sessionsRef $ Map.insert sessionId userId sessions
          return sessionId
    
    let validateSession cookieValue = do
          case UUID.fromText cookieValue of
            Nothing -> return Nothing
            Just uuid -> do
              sessions <- liftIO $ readIORef sessionsRef
              case Map.lookup uuid sessions of
                Nothing -> return Nothing
                Just userId -> return $ Just (uuid, userId)
    
    let getUserById targetUserId = do
          users <- liftIO $ readIORef usersRef
          return $ find (\u -> userId u == targetUserId) $ HM.elems users

    -- Authentication function - performs the checks inline and sets the auth in context  
    let requireAuth :: ActionM Int  -- Returns the userId if validated
        requireAuth = do
          mCookie <- header "Cookie"
          case mCookie of
            Nothing -> do
              status status401
              json $ object ["error" .= ("Authentication required" :: T.Text)]
              next
            Just cookieStrLazy -> do
              let cookieStr = TL.unpack cookieStrLazy
              let cookiePairs = map (span (/= '=') . dropWhile (== ' ')) $ splitOn ';' cookieStr
              let foundSession = lookup "session_id" $ map (\(k,v) -> (k, if not (null v) then tail v else v)) cookiePairs
              case foundSession of
                Nothing -> do
                  status status401
                  json $ object ["error" .= ("Authentication required" :: T.Text)]
                  next
                Just cookieValue -> do
                  mSession <- validateSession $ T.pack cookieValue
                  case mSession of
                    Nothing -> do
                      status status401
                      json $ object ["error" .= ("Authentication required" :: T.Text)]
                      next
                    Just (_, userId) -> return userId

    -- Registration Endpoint (no auth needed) 
    post "/register" $ do
      body' <- body
      case eitherDecode body' of
        Left err -> do
          status status400
          json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
        Right userObj -> case parseMaybe parseUserRegistration userObj of
          Nothing -> do
            status status400
            json $ object ["error" .= ("Invalid username or password" :: T.Text)]
          Just (usernameVal, passwordVal) -> do
            if T.length usernameVal < 3 || T.length usernameVal > 50
              then do
                status status400
                json $ object ["error" .= ("Invalid username" :: T.Text)]
              else if not $ T.all (\c -> c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') usernameVal
              then do
                status status400
                json $ object ["error" .= ("Invalid username" :: T.Text)]
              else if T.length passwordVal < 8
              then do  
                status status400
                json $ object ["error" .= ("Password too short" :: T.Text)]
              else do
                users <- liftIO $ readIORef usersRef
                if HM.member usernameVal users
                  then do
                    status status409
                    json $ object ["error" .= ("Username already exists" :: T.Text)]
                  else do
                    newId <- liftIO getUserId
                    let hashedPassword = hashPassword passwordVal  
                    let newUser = User newId usernameVal hashedPassword
                    liftIO $ modifyIORef usersRef $ HM.insert usernameVal newUser
                    status status201
                    json $ object [ "id" .= newId, "username" .= usernameVal ] 

    -- Login Endpoint (no auth needed)
    post "/login" $ do
      body' <- body
      case eitherDecode body' of
        Left err -> do
          status status401
          json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
        Right userObj -> case parseMaybe parseLogin userObj of
          Nothing -> do 
            status status401
            json $ object ["error" .= ("Invalid credentials" :: T.Text)]
          Just (usernameVal, passwordVal) -> do
            users <- liftIO $ readIORef usersRef
            case HM.lookup usernameVal users of
              Nothing -> do
                status status401
                json $ object ["error" .= ("Invalid credentials" :: T.Text)]
              Just user -> 
                if userPassword user /= hashPassword passwordVal
                  then do
                    status status401
                    json $ object ["error" .= ("Invalid credentials" :: T.Text)]
                  else do
                    sessionId <- addSession (userId user)
                    addHeader "Set-Cookie" $ T.pack ("session_id=" ++ UUID.toString sessionId ++ "; Path=/; HttpOnly")
                    status status200
                    json $ object [ "id" .= userId user, "username" .= username user ]

    -- Logout Endpoint
    post "/logout" $ do
      userId <- requireAuth
      mCookie <- header "Cookie"
      case mCookie of
        Nothing -> return ()
        Just cookieStrLazy -> do
          let cookieStr = TL.unpack cookieStrLazy
          let cookiePairs = map (span (/= '=') . dropWhile (== ' ')) $ splitOn ';' cookieStr
          let foundSession = lookup "session_id" $ map (\(k,v) -> (k, if not (null v) then tail v else v)) cookiePairs
          case foundSession of
            Nothing -> return ()
            Just sessionIdStr -> do
              case UUID.fromText $ T.pack sessionIdStr of
                Nothing -> return ()
                Just uuid -> do
                  liftIO $ modifyIORef sessionsRef $ Map.delete uuid
      json $ object []

    -- User Info Endpoint
    get "/me" $ do
      userId <- requireAuth
      users <- liftIO $ readIORef usersRef
      case find (\u -> userId u == userId) (HM.elems users) of
        Nothing -> do
          status status401
          json $ object ["error" .= ("Authentication required" :: T.Text)]
        Just user -> json $ object [ "id" .= userId user, "username" .= username user ]

    -- Change Password Endpoint
    put "/password" $ do
      targetUserId <- requireAuth
      body' <- body
      case eitherDecode body' of
        Left err -> do
          status status400
          json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
        Right passObj -> case parseMaybe parsePasswordChange passObj of
          Nothing -> do
            status status400
            json $ object ["error" .= ("Missing old_password or new_password" :: T.Text)]
          Just (oldPass, newPass) -> 
            if T.length newPass < 8 
              then do
                status status400
                json $ object ["error" .= ("Password too short" :: T.Text)]
              else do
                users <- liftIO $ readIORef usersRef
                let maybeUser = find (\u -> userId u == targetUserId) (HM.elems users)
                case maybeUser of
                  Nothing -> do
                    status status401
                    json $ object ["error" .= ("Authentication required" :: T.Text)]
                  Just user -> 
                    if userPassword user /= hashPassword oldPass
                      then do
                        status status401
                        json $ object ["error" .= ("Invalid credentials" :: T.Text)]
                      else do
                        let updatedUser = user { userPassword = hashPassword newPass }
                        liftIO $ modifyIORef usersRef $ HM.insert (username user) updatedUser
                        json $ object []

    -- List Todos Endpoint
    get "/todos" $ do
      userId <- requireAuth
      todos <- liftIO $ readIORef todosRef
      let userTodos = filter (\t -> todoOwnerId t == userId) todos
      json userTodos

    -- Create Todo Endpoint
    post "/todos" $ do
      userId <- requireAuth
      body' <- body
      case eitherDecode body' of
        Left err -> do
          status status400
          json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
        Right todoObj -> case parseMaybe parseTodoCreation todoObj of
          Nothing -> do
            status status400
            json $ object ["error" .= ("Title is required" :: T.Text)]
          Just (title, description) -> 
            if T.null title
              then do
                status status400  
                json $ object ["error" .= ("Title is required" :: T.Text)]
              else do
                timestamp <- liftIO nowUTC
                newTodoId <- liftIO getTodoId
                let newTodo = Todo 
                            { todoId = newTodoId
                            , todoTitle = title
                            , todoDescription = description
                            , todoCompleted = False
                            , createdAt = timestamp
                            , updatedAt = timestamp
                            , todoOwnerId = userId
                            }
                liftIO $ modifyIORef todosRef (++ [newTodo])
                status status201
                json newTodo

    -- Get Specific Todo Endpoint
    get "/todos/:id" $ do
      idText <- param "id"
      case decimal idText of
        Left _ -> do
          status status404
          json $ object ["error" .= ("Todo not found" :: T.Text)]
        Right (todoIdInt, rest) -> if not (T.null rest) 
                                  then do
                                    status status404
                                    json $ object ["error" .= ("Todo not found" :: T.Text)] 
                                  else do
            userId <- requireAuth
            todos <- liftIO $ readIORef todosRef
            case find (\t -> todoId t == todoIdInt && todoOwnerId t == userId) todos of
              Nothing -> do
                status status404
                json $ object ["error" .= ("Todo not found" :: T.Text)]
              Just todo -> json todo

    -- Update Todo Endpoint  
    put "/todos/:id" $ do
      idText <- param "id"
      case decimal idText of
        Left _ -> do
          status status404
          json $ object ["error" .= ("Todo not found" :: T.Text)]
        Right (todoIdInt, rest) -> if not (T.null rest) 
                                  then do
                                    status status404
                                    json $ object ["error" .= ("Todo not found" :: T.Text)] 
                                  else do
            userId <- requireAuth
            body' <- body
            case eitherDecode body' of
              Left err -> do
                status status400
                json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
              Right updateObj -> do
                let mTitleRaw = parseMaybe (.:? "title") updateObj
                let mDescRaw = parseMaybe (.:? "description") updateObj
                let mCompletedRaw = parseMaybe (.:? "completed") updateObj
                
                let mTitle = mTitleRaw >>= id  -- Flattens Maybe (Maybe a) to Maybe a
                let mDesc = mDescRaw >>= id
                let mCompleted = mCompletedRaw >>= id
                
                case mTitle of
                  Just "" -> do  -- Empty title validation
                    status status400
                    json $ object ["error" .= ("Title is required" :: T.Text)]
                  _ -> do
                    todosRefVal <- liftIO $ readIORef todosRef
                    case find (\t -> todoId t == todoIdInt && todoOwnerId t == userId) todosRefVal of
                      Nothing -> do
                        status status404
                        json $ object ["error" .= ("Todo not found" :: T.Text)]
                      Just todoToUpdate -> do
                        timestamp <- liftIO nowUTC
                        let updatedTitle = fromMaybe (todoTitle todoToUpdate) mTitle
                        let updatedDesc = fromMaybe (todoDescription todoToUpdate) mDesc
                        let updatedCompleted = fromMaybe (todoCompleted todoToUpdate) mCompleted
                        
                        let updatedTodo = todoToUpdate
                                    { todoTitle = updatedTitle
                                    , todoDescription = updatedDesc  
                                    , todoCompleted = updatedCompleted
                                    , updatedAt = timestamp
                                    }
                        
                        let updatedTodos = map (\t -> if todoId t == todoIdInt then updatedTodo else t) todosRefVal
                        liftIO $ writeIORef todosRef updatedTodos
                        json updatedTodo

    -- Delete Todo Endpoint
    delete "/todos/:id" $ do
      idText <- param "id"
      case decimal idText of
        Left _ -> do
          status status404
          json $ object ["error" .= ("Todo not found" :: T.Text)]
        Right (todoIdInt, rest) -> if not (T.null rest) 
                                  then do
                                    status status404
                                    json $ object ["error" .= ("Todo not found" :: T.Text)] 
                                  else do
            userId <- requireAuth
            todosRefVal <- liftIO $ readIORef todosRef
            case find (\t -> todoId t == todoIdInt && todoOwnerId t == userId) todosRefVal of
              Nothing -> do
                status status404
                json $ object ["error" .= ("Todo not found" :: T.Text)]
              Just _ -> do
                let filteredTodos = filter (\t -> todoId t /= todoIdInt) todosRefVal
                liftIO $ writeIORef todosRef filteredTodos
                status status204


-- Parser functions to handle JSON parsing properly

parseUserRegistration :: Object -> Parser (T.Text, T.Text)
parseUserRegistration o = (,) 
                          <$> o .: "username" 
                          <*> o .: "password"

parseLogin :: Object -> Parser (T.Text, T.Text)
parseLogin o = (,)
               <$> o .: "username"
               <*> o .: "password"
               
parsePasswordChange :: Object -> Parser (T.Text, T.Text)
parsePasswordChange o = (,)
                        <$> o .: "old_password" 
                        <*> o .: "new_password"
                        
parseTodoCreation :: Object -> Parser (T.Text, T.Text)
parseTodoCreation o = (,) 
                      <$> o .: "title" 
                      <*> o .:? "description" .!= ""