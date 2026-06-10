{-# LANGUAGE OverloadedStrings #-}
module Main where

import Web.Scotty
import Network.HTTP.Types hiding (Header)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Aeson
import Data.Time
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Data.ByteString.Lazy.Char8 as BS (ByteString)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Read as TR
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map
import Data.Time.Format.ISO8601 (iso8601Show)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe, isNothing, isJust)
import Data.List (find)
import Lib
import Data.IORef

-- Parse JSON utility function for extracting values robustly
parseJsonField :: Value -> T.Text -> Maybe T.Text
parseJsonField (Object obj) fieldName = case obj ^. key fieldName of
    String str -> Just str
    _ -> Nothing
parseJsonField _ _ = Nothing

-- Main application
main :: IO ()
main = do
  args <- getArgs
  let port = if "--port" `elem` args
             then read $ args !! (length args - 1)
             else 3000
   
  putStrLn $ "Starting server on port: " ++ show port
  -- Initialize global state refs
  usersRef <- newIORef HM.empty
  todosRef <- newIORef []
  sessionsRef <- newIORef Map.empty
  userIdCounterRef <- newIORef 1
  todoIdCounterRef <- newIORef 1

  scotty port $ app usersRef todosRef sessionsRef userIdCounterRef todoIdCounterRef

{- Using explicit lenses for JSON parsing to avoid complex dependencies -}
import qualified Data.Vector as V
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap

getValueByKey :: Key.Key -> Object -> Maybe Value
getValueByKey k = KeyMap.lookup k 

parseJsonField' :: Value -> T.Text -> Maybe T.Text
parseJsonField' (Object obj) fieldName = 
  case getValueByKey (Key.fromText fieldName) obj of
    Just (String str) -> Just str
    Just (Number n) -> Just (T.pack $ show n)
    _ -> Nothing
parseJsonField' _ _ = Nothing

parseJsonFieldBool :: Value -> T.Text -> Maybe Bool
parseJsonFieldBool (Object obj) fieldName = 
  case getValueByKey (Key.fromText fieldName) obj of
    Just (Bool b) -> Just b
    _ -> Nothing
parseJsonFieldBool _ _ = Nothing

parseValue :: FromJSON a => Value -> Maybe a
parseValue v = case fromJSON v of
    Success a -> Just a
    Error _ -> Nothing

app :: IORef (HM.HashMap T.Text User) -> IORef [Todo] -> IORef (Map.Map UUID Int) -> IORef Int -> IORef Int -> ScottyM ()
app usersRef todosRef sessionsRef userIdCounterRef todoIdCounterRef = do
  -- Set content type for all responses
  middleware $ \request response -> 
    return $ response { responseHeaders = ("Content-Type", "application/json") : responseHeaders response }
  
  -- Helper functions that interact with state
  let getUserId = atomicModifyIORef userIdCounterRef $ \counter -> (counter + 1, counter)
  let getTodoId = atomicModifyIORef todoIdCounterRef $ \counter -> (counter + 1, counter)
  
  let addSession userId = do
        sessionId <- liftIO UUID.nextRandom
        sessions <- liftIO $ readIORef sessionsRef
        liftIO $ writeIORef sessionsRef $ Map.insert sessionId userId sessions
        return sessionId
  
  let validateSession cookieValue = do
        case UUID.fromString $ T.unpack cookieValue of
          Nothing -> return Nothing
          Just uuid -> do
            sessions <- liftIO $ readIORef sessionsRef
            case Map.lookup uuid sessions of
              Nothing -> return Nothing
              Just userId -> return $ Just (uuid, userId)
  
  let getUserByUsername uname = do
        users <- liftIO $ readIORef usersRef
        return $ HM.lookup uname users

  let getUserById uid = do
        users <- liftIO $ readIORef usersRef
        return $ find (\u -> userId u == uid) $ HM.elems users

  -- Authentication Middleware
  let requireAuth = do
        mCookies <- header "Cookie"
        let extractSessionId str = 
              let cookiePairs = map (span (/= '=') . dropWhile (== ' ')) $ splitOn ';' $ T.unpack str
              in lookup "session_id" $ map (\(k,v) -> (k, tail v)) cookiePairs
        case mCookies of
          Nothing -> do
            status status401
            json $ object ["error" .= ("Authentication required" :: T.Text)]
            rescue (return ()) $ do
              halt $ status status401
          Just cookiesStr -> case extractSessionId cookiesStr of
            Nothing -> do
              status status401
              json $ object ["error" .= ("Authentication required" :: T.Text)]
              rescue (return ()) $
                halt $ status status401
            Just cookieValue -> do
              mSession <- validateSession $ T.pack cookieValue
              case mSession of
                Nothing -> do
                  status status401
                  json $ object ["error" .= ("Authentication required" :: T.Text)]
                  rescue (return ()) $
                    halt $ status status401
                Just (sessionId, userId) -> return (sessionId, userId)
    
  let sendSessionCookie sessionId = 
        addHeader "Set-Cookie" $ "session_id=" <> UUID.toString sessionId <> "; Path=/; HttpOnly"
        
  -- Split helper function
  let splitOn delim = foldr f [[]]
        where f c l@(x:xs) | c == delim = []:l
                           | otherwise = (c:x):xs

  -- Registration Endpoint
  post "/register" $ do
    body' <- body
    case eitherDecode' body' of
      Left err -> do
        status status400
        json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
      Right userBody -> do
        -- Extract username and password
        let mUsername = parseJsonField' userBody "username" 
        let mPassword = parseJsonField' userBody "password"

        case (mUsername, mPassword) of
          (Nothing, _) -> do
            status status400
            json $ object ["error" .= ("Invalid username" :: T.Text)]
          (Just usernameVal, Nothing) -> do
            status status400
            json $ object ["error" .= ("Password is required" :: T.Text)]
          (Just usernameVal, Just passwordVal) -> do
            -- Validate username format: alphanumeric and underscore only, length 3-50
            let validChars = T.all (\c -> c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') usernameVal
            let validLength = T.length usernameVal >= 3 && T.length usernameVal <= 50
            if not (validChars && validLength)
              then do
                status status400
                json $ object ["error" .= ("Invalid username" :: T.Text)]
              else do
                -- Check password length
                if T.length passwordVal < 8
                  then do
                    status status400
                    json $ object ["error" .= ("Password too short" :: T.Text)]
                  else do
                    -- Check if user exists
                    users <- liftIO $ readIORef usersRef
                    if HM.member usernameVal users
                      then do
                        status status409
                        json $ object ["error" .= ("Username already exists" :: T.Text)]
                      else do
                        -- Create new user
                        newId <- liftIO getUserId
                        let hashedPassword = hashPassword passwordVal
                        let newUser = User newId usernameVal hashedPassword
                        
                        -- Store user
                        liftIO $ modifyIORef usersRef $ HM.insert usernameVal newUser
                        
                        -- Send response
                        status status201
                        json $ object [ "id" .= newId, "username" .= usernameVal ]

  -- Login Endpoint
  post "/login" $ do
    body' <- body
    case eitherDecode' body' of
      Left err -> do
        status status401
        json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
      Right userBody -> do
        -- Extract username and password
        let mUsername = parseJsonField' userBody "username"
        let mPassword = parseJsonField' userBody "password"
        
        case (mUsername, mPassword) of
          (Nothing, _) -> do
            status status401
            json $ object ["error" .= ("Invalid credentials" :: T.Text)]
          (Just usernameVal, Nothing) -> do
            status status401
            json $ object ["error" .= ("Invalid credentials" :: T.Text)]
          (Just usernameVal, Just passwordVal) -> do
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
                    -- Create session for user
                    sessionId <- addSession (userId user)
                    
                    -- Send session cookie with response
                    liftIO $ print $ "Setting session cookie: " ++ UUID.toString sessionId
                    addHeader "Set-Cookie" $ T.pack ("session_id=" ++ UUID.toString sessionId ++ "; Path=/; HttpOnly")
                    
                    -- Return user details without password
                    status status200
                    json $ object [ "id" .= userId user, "username" .= username user ]

  -- Logout Endpoint
  post "/logout" $ do
    (sessionId, _) <- requireAuth
    
    -- Remove the session from the store
    liftIO $ modifyIORef sessionsRef $ Map.delete sessionId
    
    -- Return success without body
    json $ object []

  -- User Info Endpoint
  get "/me" $ do
    (_, userid) <- requireAuth
    maybeUser <- getUserById userid
    case maybeUser of
      Nothing -> do
        status status401
        json $ object ["error" .= ("Authentication required" :: T.Text)]
      Just user -> json $ object [ "id" .= userId user, "username" .= username user ]

  -- Change Password Endpoint
  put "/password" $ do
    (_, userId) <- requireAuth
    body' <- body
    case eitherDecode' body' of
      Left err -> do
        status status400
        json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
      Right passBody -> do
        let mOldPassword = parseJsonField' passBody "old_password"
        let mNewPassword = parseJsonField' passBody "new_password"
        
        case (mOldPassword, mNewPassword) of
          (Nothing, _) -> do
            status status400
            json $ object ["error" .= ("Missing old_password or new_password" :: T.Text)]
          (_, Nothing) -> do
            status status400
            json $ object ["error" .= ("Missing old_password or new_password" :: T.Text)]
          (Just oldPass, Just newPass) -> do
            if T.length newPass < 8
              then do
                status status400
                json $ object ["error" .= ("Password too short" :: T.Text)]
              else do
                -- Find user and check old password
                userOpt <- getUserById userId
                case userOpt of
                  Nothing -> do
                    status status401
                    json $ object ["error" .= ("Authentication required" :: T.Text)]
                  Just user -> do
                    if userPassword user /= hashPassword oldPass
                      then do
                        status status401
                        json $ object ["error" .= ("Invalid credentials" :: T.Text)]
                      else do
                        -- Update password
                        let updatedUser = user { userPassword = hashPassword newPass }
                        liftIO $ modifyIORef usersRef $ HM.insert (username user) updatedUser
                        json $ object []

  -- List Todos Endpoint
  get "/todos" $ do
    (_, uid) <- requireAuth
    todos <- liftIO $ readIORef todosRef
    let userTodos = filter (\t -> todoOwnerId t == uid) todos
    json userTodos

  -- Create Todo Endpoint
  post "/todos" $ do
    (_, userId) <- requireAuth
    body' <- body
    case eitherDecode' body' of
      Left err -> do
        status status400
        json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
      Right todoBody -> do
        let mTitle = parseJsonField' todoBody "title"
        let mDescription = fromMaybe "" $ parseJsonField' todoBody "description"  -- defaults to empty string
        
        case mTitle of
          Nothing -> do
            status status400
            json $ object ["error" .= ("Title is required" :: T.Text)]
          Just title -> do
            if T.null title
              then do
                status status400
                json $ object ["error" .= ("Title is required" :: T.Text)]
              else do
                let description = mDescription
                timestamp <- liftIO nowUTC
                
                newTodoId <- liftIO getTodoId
                
                let newTodo = Todo 
                            { todoId = newTodoId
                            , todoTitle = title
                            , todoDescription = description
                            , todoCompleted = False  -- Default to false
                            , createdAt = timestamp
                            , updatedAt = timestamp
                            , todoOwnerId = userId
                            }
                
                -- Add to todos
                liftIO $ modifyIORef todosRef (++ [newTodo])
                
                -- Return created todo
                status status201
                json newTodo

  -- Get Specific Todo Endpoint
  get "/todos/:id" $ do
    paramId <- param "id"
    case TR.decimal paramId of
      Left _ -> do
        status status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]
      Right (todoIdInt, "") -> do  -- Ensures entire string was parsed
        (_, userId) <- requireAuth
        todos <- liftIO $ readIORef todosRef
        case find (\t -> todoId t == todoIdInt && todoOwnerId t == userId) todos of
          Nothing -> do
            status status404
            json $ object ["error" .= ("Todo not found" :: T.Text)]
          Just todo -> json todo
      Right _ -> do  -- Extra characters after number
        status status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]

  -- Update Todo Endpoint
  put "/todos/:id" $ do
    paramId <- param "id"
    case TR.decimal paramId of
      Left _ -> do
        status status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]
      Right (todoIdInt, "") -> do  -- Ensures entire string was parsed
        (_, userId) <- requireAuth
        
        -- Parse the update data
        body' <- body
        case eitherDecode' body' of
          Left err -> do
            status status400
            json $ object ["error" .= ("Invalid JSON format" :: T.Text)]
          Right updateBody -> do
            -- Process the update data, allowing for partial updates
            mTitle <- case parseJsonField' updateBody "title" of
                         Nothing -> return Nothing
                         Just t -> if T.null t
                                 then do
                                   status status400
                                   json $ object ["error" .= ("Title is required" :: T.Text)]
                                   rescue (return ()) $ halt $ status status400
                                 else return $ Just t
        
            let mDescription = parseJsonField' updateBody "description"
            let mCompleted = parseJsonFieldBool updateBody "completed"
            
            -- Retrieve all todos and find the one to update
            todosRefVal <- liftIO $ readIORef todosRef
            case find (\t -> todoId t == todoIdInt && todoOwnerId t == userId) todosRefVal of
              Nothing -> do
                status status404
                json $ object ["error" .= ("Todo not found" :: T.Text)]
              Just todoToUpdate -> do
                -- Update the todo fields if they were provided in the payload
                timestamp <- liftIO nowUTC
                let updatedTitle = fromMaybe (todoTitle todoToUpdate) mTitle
                let updatedDesc = fromMaybe (todoDescription todoToUpdate) mDescription
                let updatedCompleted = fromMaybe (todoCompleted todoToUpdate) mCompleted
                
                let updatedTodo = todoToUpdate 
                                { todoTitle = updatedTitle
                                , todoDescription = updatedDesc
                                , todoCompleted = updatedCompleted
                                , updatedAt = timestamp
                                }
                
                -- Update in storage
                let updatedTodos = map (\t -> if todoId t == todoIdInt then updatedTodo else t) todosRefVal
                liftIO $ writeIORef todosRef updatedTodos
                
                -- Return the updated todo
                json updatedTodo
      Right _ -> do  -- Extra characters after number
        status status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]

  -- Delete Todo Endpoint
  delete "/todos/:id" $ do
    paramId <- param "id"
    case TR.decimal paramId of
      Left _ -> do
        status status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]
      Right (todoIdInt, "") -> do  -- Ensures entire string was parsed
        (_, userId) <- requireAuth
        
        todosRefVal <- liftIO $ readIORef todosRef
        case find (\t -> todoId t == todoIdInt && todoOwnerId t == userId) todosRefVal of
          Nothing -> do
            status status404
            json $ object ["error" .= ("Todo not found" :: T.Text)]
          Just _ -> do
            -- Delete the todo
            let filteredTodos = filter (\t -> todoId t /= todoIdInt) todosRefVal
            liftIO $ writeIORef todosRef filteredTodos
            
            -- Return 204 No Content (no body)
            status status204
            raw ""
      Right _ -> do  -- Extra chars after number
        status status404
        json $ object ["error" .= ("Todo not found" :: T.Text)]