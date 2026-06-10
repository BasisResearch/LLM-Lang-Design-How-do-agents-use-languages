{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
module Main where

import           Control.Concurrent.STM
import           Control.Monad.IO.Class (liftIO)
import           Control.Applicative ((<|>))
import           Data.Aeson
import qualified Data.Aeson as A
import           Data.Aeson.Types (Parser)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BL
import           Data.Char (isAlphaNum)
import           Data.List (sortOn)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe (fromMaybe)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time
import           GHC.Generics (Generic)
import           Network.HTTP.Types (Status, status201, status204, status400, status401, status404, status409)
import           Network.Wai (Request(..), requestHeaders, Middleware, mapResponseHeaders, requestMethod)
import           Network.Wai.Handler.Warp (defaultSettings, setHost, setPort, runSettings)
import           Web.Cookie (parseCookies)
import qualified Web.Scotty as S
import qualified Data.UUID.V4 as UUID
import qualified Data.UUID as UUID
import           System.Environment (getArgs)
import           Data.String (fromString)

-- Data types

data User = User
  { userId   :: Int
  , username :: Text
  } deriving (Show, Eq, Generic)

instance ToJSON User where
  toJSON (User uid uname) = object ["id" .= uid, "username" .= uname]

-- Internal stored user with password

data UserRec = UserRec
  { uId       :: Int
  , uName     :: Text
  , uPassword :: Text
  } deriving (Show, Eq)

-- Todo record (internal)

data TodoRec = TodoRec
  { tId         :: Int
  , tOwnerId    :: Int
  , tTitle      :: Text
  , tDesc       :: Text
  , tCompleted  :: Bool
  , tCreatedAt  :: UTCTime
  , tUpdatedAt  :: UTCTime
  } deriving (Show, Eq)

-- Public JSON representation for TodoRec
instance ToJSON TodoRec where
  toJSON t = object
    [ "id" .= tId t
    , "title" .= tTitle t
    , "description" .= tDesc t
    , "completed" .= tCompleted t
    , "created_at" .= formatUtc (tCreatedAt t)
    , "updated_at" .= formatUtc (tUpdatedAt t)
    ]

formatUtc :: UTCTime -> String
formatUtc = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- Request bodies

data RegisterReq = RegisterReq
  { rrUsername :: Maybe Text
  , rrPassword :: Maybe Text
  } deriving (Show, Generic)

instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> do
    rrUsername <- o .:? "username"
    rrPassword <- o .:? "password"
    return RegisterReq{..}

data LoginReq = LoginReq
  { lrUsername :: Maybe Text
  , lrPassword :: Maybe Text
  } deriving (Show, Generic)

instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> do
    lrUsername <- o .:? "username"
    lrPassword <- o .:? "password"
    return LoginReq{..}

-- Password change

data PasswordReq = PasswordReq
  { prOld :: Maybe Text
  , prNew :: Maybe Text
  } deriving (Show, Generic)

instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \o -> do
    prOld <- o .:? "old_password"
    prNew <- o .:? "new_password"
    return PasswordReq{..}

-- Create todo

data CreateTodoReq = CreateTodoReq
  { ctrTitle :: Maybe Text
  , ctrDesc  :: Maybe Text
  } deriving (Show, Generic)

instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \o -> do
    ctrTitle <- o .:? "title"
    ctrDesc  <- o .:? "description"
    return CreateTodoReq{..}

-- Update todo (partial)

data UpdateTodoReq = UpdateTodoReq
  { utrTitle     :: Maybe (Maybe Text) -- present and maybe empty
  , utrDesc      :: Maybe (Maybe Text)
  , utrCompleted :: Maybe Bool
  } deriving (Show)

instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> do
    -- We need to know if title key is present and if so its value (possibly empty string)
    let optText k = (Just <$> (o .: k)) <|> pure Nothing
    utrTitle     <- optText "title"
    utrDesc      <- optText "description"
    utrCompleted <- o .:? "completed"
    return UpdateTodoReq{..}

-- Server state

data ServerState = ServerState
  { nextUserIdVar :: TVar Int
  , usersByIdVar  :: TVar (Map Int UserRec)
  , usersByNameVar:: TVar (Map Text Int)
  , sessionsVar   :: TVar (Map Text Int) -- session token -> userId
  , nextTodoIdVar :: TVar Int
  , todosVar      :: TVar (Map Int TodoRec)
  }

newServerState :: IO ServerState
newServerState = atomically $ do
  nu <- newTVar 1
  ubid <- newTVar M.empty
  ubn <- newTVar M.empty
  sess <- newTVar M.empty
  nt <- newTVar 1
  td <- newTVar M.empty
  return $ ServerState nu ubid ubn sess nt td

-- Utilities
jsonError :: Status -> Text -> S.ActionM ()
jsonError st msg = do
  S.status st
  S.json (object ["error" .= msg])

validateUsername :: Text -> Bool
validateUsername u =
  let l = T.length u
   in l >= 3 && l <= 50 && T.all (\c -> isAlphaNum c || c == '_') u

requireAuth :: ServerState -> S.ActionM (UserRec, Text)
requireAuth st = do
  req <- S.request
  let mCookieHeader = lookup "Cookie" (requestHeaders req)
      mToken = do
        ch <- mCookieHeader
        let cookies = parseCookies ch
        fmap (T.pack . BS.unpack) $ lookup "session_id" cookies
  case mToken of
    Nothing -> do
      jsonError status401 "Authentication required"
      S.finish
    Just tok -> do
      mu <- liftIO $ atomically $ do
        m <- readTVar (sessionsVar st)
        case M.lookup tok m of
          Nothing -> return Nothing
          Just uid -> do
            users <- readTVar (usersByIdVar st)
            return $ (,) <$> M.lookup uid users <*> Just tok
      case mu of
        Nothing -> do
          jsonError status401 "Authentication required"
          S.finish
        Just (u, t) -> return (u, t)

-- Helper to get current UTC time
nowUtc :: IO UTCTime
nowUtc = getCurrentTime

-- Convert internal user to public
publicUser :: UserRec -> User
publicUser ur = User (uId ur) (uName ur)

-- Safe JSON body parser that returns Nothing on parse error or empty body
getJsonBody :: FromJSON a => S.ActionM (Maybe a)
getJsonBody = do
  b <- S.body
  if BL.null b
    then return Nothing
    else case A.eitherDecode' b of
           Left _  -> return Nothing
           Right v -> return (Just v)

-- Middleware to enforce Content-Type application/json on all non-DELETE responses
jsonContentMiddleware :: Middleware
jsonContentMiddleware app req send =
  app req $ \rsp ->
    if requestMethod req == "DELETE"
      then send rsp
      else send (mapResponseHeaders (setJsonCT) rsp)
  where
    setJsonCT hs = ("Content-Type", "application/json") : filter ((/= "Content-Type") . fst) hs

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
                ("--port":p:_) -> read p
                _               -> 3000 :: Int
  st <- newServerState
  app <- S.scottyApp $ do
    -- apply middleware
    S.middleware jsonContentMiddleware

    -- Routes

    S.post "/register" $ do
      mBody <- getJsonBody :: S.ActionM (Maybe RegisterReq)
      let bodyVal = fromMaybe (RegisterReq Nothing Nothing) mBody
      case (rrUsername bodyVal, rrPassword bodyVal) of
        (Just u, _) | not (validateUsername u) -> jsonError status400 "Invalid username"
        (Just _, Just p) | T.length p < 8 -> jsonError status400 "Password too short"
        (Nothing, _) -> jsonError status400 "Invalid username"
        (Just _, Nothing) -> jsonError status400 "Password too short"
        (Just u, Just p) -> do
          res <- liftIO $ atomically $ do
            usersByName <- readTVar (usersByNameVar st)
            if M.member u usersByName
              then return (Left ())
              else do
                uid <- readTVar (nextUserIdVar st)
                modifyTVar' (nextUserIdVar st) (+1)
                let ur = UserRec uid u p
                modifyTVar' (usersByIdVar st) (M.insert uid ur)
                modifyTVar' (usersByNameVar st) (M.insert u uid)
                return (Right ur)
          case res of
            Left _ -> jsonError status409 "Username already exists"
            Right ur -> do
              S.status status201
              S.json (toJSON (publicUser ur))

    S.post "/login" $ do
      mBody <- getJsonBody :: S.ActionM (Maybe LoginReq)
      let bodyVal = fromMaybe (LoginReq Nothing Nothing) mBody
      let mU = lrUsername bodyVal
          mP = lrPassword bodyVal
      case (mU, mP) of
        (Just u, Just p) -> do
          mres <- liftIO $ atomically $ do
            ubn <- readTVar (usersByNameVar st)
            case M.lookup u ubn of
              Nothing -> return Nothing
              Just uid -> do
                ubid <- readTVar (usersByIdVar st)
                case M.lookup uid ubid of
                  Nothing -> return Nothing
                  Just ur -> if uPassword ur == p
                               then return (Just ur)
                               else return Nothing
          case mres of
            Nothing -> jsonError status401 "Invalid credentials"
            Just ur -> do
              tok <- liftIO $ (T.pack . UUID.toString) <$> UUID.nextRandom
              liftIO $ atomically $ modifyTVar' (sessionsVar st) (M.insert tok (uId ur))
              S.setHeader "Set-Cookie" (fromString $ "session_id=" ++ T.unpack tok ++ "; Path=/; HttpOnly")
              S.json (toJSON (publicUser ur))
        _ -> jsonError status401 "Invalid credentials"

    S.post "/logout" $ do
      (_, tok) <- requireAuth st
      -- invalidate session
      liftIO $ atomically $ modifyTVar' (sessionsVar st) (M.delete tok)
      S.json (object [])

    S.get "/me" $ do
      (ur, _) <- requireAuth st
      S.json (toJSON (publicUser ur))

    S.put "/password" $ do
      (ur, _) <- requireAuth st
      mBody <- getJsonBody :: S.ActionM (Maybe PasswordReq)
      let bodyVal = fromMaybe (PasswordReq Nothing Nothing) mBody
      case (prOld bodyVal, prNew bodyVal) of
        (Just oldp, Just newp) -> do
          if oldp /= uPassword ur
            then jsonError status401 "Invalid credentials"
            else if T.length newp < 8
              then jsonError status400 "Password too short"
              else do
                liftIO $ atomically $ modifyTVar' (usersByIdVar st) (M.adjust (\u -> u { uPassword = newp }) (uId ur))
                S.json (object [])
        (Just _, Nothing) -> jsonError status400 "Password too short"
        _ -> jsonError status401 "Invalid credentials"

    S.get "/todos" $ do
      (ur, _) <- requireAuth st
      todos <- liftIO $ atomically $ readTVar (todosVar st)
      let own = filter ((== uId ur) . tOwnerId) (M.elems todos)
          ordered = sortOn tId own
      S.json (toJSON ordered)

    S.post "/todos" $ do
      (ur, _) <- requireAuth st
      mBody <- getJsonBody :: S.ActionM (Maybe CreateTodoReq)
      let bodyVal = fromMaybe (CreateTodoReq Nothing Nothing) mBody
      case ctrTitle bodyVal of
        Nothing -> jsonError status400 "Title is required"
        Just t | T.null t -> jsonError status400 "Title is required"
        Just t -> do
          let desc = fromMaybe "" (ctrDesc bodyVal)
          now <- liftIO nowUtc
          newTodo <- liftIO $ atomically $ do
            tid <- readTVar (nextTodoIdVar st)
            modifyTVar' (nextTodoIdVar st) (+1)
            let tr = TodoRec tid (uId ur) t desc False now now
            modifyTVar' (todosVar st) (M.insert tid tr)
            return tr
          S.status status201
          S.json (toJSON newTodo)

    S.get "/todos/:id" $ do
      (ur, _) <- requireAuth st
      tid <- S.pathParam "id" :: S.ActionM Int
      mt <- liftIO $ atomically $ do
        m <- readTVar (todosVar st)
        return $ M.lookup tid m
      case mt of
        Nothing -> jsonError status404 "Todo not found"
        Just tr -> if tOwnerId tr /= uId ur
                     then jsonError status404 "Todo not found"
                     else S.json (toJSON tr)

    S.put "/todos/:id" $ do
      (ur, _) <- requireAuth st
      tid <- S.pathParam "id" :: S.ActionM Int
      mBody <- getJsonBody :: S.ActionM (Maybe UpdateTodoReq)
      let bodyVal = fromMaybe (UpdateTodoReq Nothing Nothing Nothing) mBody
      mt <- liftIO $ atomically $ do
        m <- readTVar (todosVar st)
        return $ M.lookup tid m
      case mt of
        Nothing -> jsonError status404 "Todo not found"
        Just tr -> if tOwnerId tr /= uId ur
                      then jsonError status404 "Todo not found"
                      else do
                        -- Validate title if provided and empty
                        case utrTitle bodyVal of
                          Just (Just t) | T.null t -> jsonError status400 "Title is required"
                          _ -> do
                            now <- liftIO nowUtc
                            let newTitle = case utrTitle bodyVal of
                                             Nothing -> tTitle tr
                                             Just Nothing -> tTitle tr
                                             Just (Just t) -> t
                                newDesc = case utrDesc bodyVal of
                                             Nothing -> tDesc tr
                                             Just Nothing -> tDesc tr
                                             Just (Just d) -> d
                                newComp = fromMaybe (tCompleted tr) (utrCompleted bodyVal)
                                tr' = tr { tTitle = newTitle
                                         , tDesc = newDesc
                                         , tCompleted = newComp
                                         , tUpdatedAt = now }
                            liftIO $ atomically $ modifyTVar' (todosVar st) (M.insert tid tr')
                            S.json (toJSON tr')

    S.delete "/todos/:id" $ do
      (ur, _) <- requireAuth st
      tid <- S.pathParam "id" :: S.ActionM Int
      res <- liftIO $ atomically $ do
        m <- readTVar (todosVar st)
        case M.lookup tid m of
          Nothing -> return (Left ())
          Just tr -> if tOwnerId tr /= uId ur
                        then return (Left ())
                        else do
                          modifyTVar' (todosVar st) (M.delete tid)
                          return (Right ())
      case res of
        Left _ -> jsonError status404 "Todo not found"
        Right _ -> do
          S.status status204
          return ()

  let settings = setPort port $ setHost (fromString "0.0.0.0") defaultSettings
  runSettings settings app
