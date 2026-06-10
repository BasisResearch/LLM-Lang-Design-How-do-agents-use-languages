{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import           Control.Concurrent.STM
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad (when, unless)
import           Data.Aeson (FromJSON(..), ToJSON(..), (.:), (.:?), withObject, object, (.=))
import qualified Data.Aeson as A
import           Data.List (sortOn, find)
import           Data.Maybe (fromMaybe)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time
import           GHC.Generics (Generic)
import           Network.Wai.Handler.Warp (runSettings, defaultSettings, setPort, setHost)
import           Network.Wai (Application)
import           Network.HTTP.Types (hContentType)
import           Servant
import           System.Environment (getArgs)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Builder as BB
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import           Web.Cookie

-- Data types

data User = User { userId :: Int, username :: Text } deriving (Show, Eq, Generic)
instance ToJSON User

-- Internal user with password

data IUser = IUser { iUser :: User, iPassword :: Text } deriving (Show, Eq)

-- Todo object

data Todo = Todo
  { todoId      :: Int
  , todoUserId  :: Int
  , title       :: Text
  , description :: Text
  , completed   :: Bool
  , createdAt   :: Text
  , updatedAt   :: Text
  } deriving (Show, Eq, Generic)
instance ToJSON Todo where
  toJSON (Todo i _ t d c ca ua) = object
    [ "id" .= i
    , "title" .= t
    , "description" .= d
    , "completed" .= c
    , "created_at" .= ca
    , "updated_at" .= ua
    ]

-- Requests

data RegisterReq = RegisterReq { rrUsername :: Text, rrPassword :: Text } deriving (Generic, Show)
instance FromJSON RegisterReq where
  parseJSON = withObject "RegisterReq" $ \o -> RegisterReq <$> o .: "username" <*> o .: "password"

data LoginReq = LoginReq { lrUsername :: Text, lrPassword :: Text } deriving (Generic, Show)
instance FromJSON LoginReq where
  parseJSON = withObject "LoginReq" $ \o -> LoginReq <$> o .: "username" <*> o .: "password"

data PasswordReq = PasswordReq { old_password :: Text, new_password :: Text } deriving (Generic, Show)
instance FromJSON PasswordReq where
  parseJSON = withObject "PasswordReq" $ \o -> PasswordReq <$> o .: "old_password" <*> o .: "new_password"

data CreateTodoReq = CreateTodoReq { ctTitle :: Text, ctDescription :: Maybe Text } deriving (Show)
instance FromJSON CreateTodoReq where
  parseJSON = withObject "CreateTodoReq" $ \o -> CreateTodoReq <$> o .: "title" <*> o .:? "description"

data UpdateTodoReq = UpdateTodoReq { utTitle :: Maybe Text, utDescription :: Maybe Text, utCompleted :: Maybe Bool } deriving (Show)
instance FromJSON UpdateTodoReq where
  parseJSON = withObject "UpdateTodoReq" $ \o -> UpdateTodoReq <$> o .:? "title" <*> o .:? "description" <*> o .:? "completed"

-- Store

data Store = Store
  { users      :: TVar [IUser]
  , nextUserId :: TVar Int
  , sessions   :: TVar [(Text, Int)] -- token -> userId
  , todos      :: TVar [Todo]
  , nextTodoId :: TVar Int
  }

mkStore :: IO Store
mkStore = atomically $ do
  us <- newTVar []
  nu <- newTVar 1
  ss <- newTVar []
  ts <- newTVar []
  nt <- newTVar 1
  pure $ Store us nu ss ts nt

-- API

type API =
       "register" :> ReqBody '[JSON] RegisterReq :> PostCreated '[JSON] User
  :<|> "login"    :> ReqBody '[JSON] LoginReq    :> Post '[JSON] (Headers '[Header "Set-Cookie" String] User)
  :<|> "logout"   :> Header "Cookie" Text        :> Post '[JSON] A.Value
  :<|> "me"       :> Header "Cookie" Text        :> Get '[JSON] User
  :<|> "password" :> Header "Cookie" Text :> ReqBody '[JSON] PasswordReq :> Put '[JSON] A.Value
  :<|> "todos"    :> Header "Cookie" Text :> Get '[JSON] [Todo]
  :<|> "todos"    :> Header "Cookie" Text :> ReqBody '[JSON] CreateTodoReq :> PostCreated '[JSON] Todo
  :<|> "todos"    :> Header "Cookie" Text :> Capture "id" Int :> Get '[JSON] Todo
  :<|> "todos"    :> Header "Cookie" Text :> Capture "id" Int :> ReqBody '[JSON] UpdateTodoReq :> Put '[JSON] Todo
  :<|> "todos"    :> Header "Cookie" Text :> Capture "id" Int :> DeleteNoContent

server :: Store -> Server API
server st = registerH :<|> loginH :<|> logoutH :<|> meH :<|> passH :<|> listH :<|> createH :<|> getH :<|> updateH :<|> deleteH
  where
    jsonErr :: ServerError -> Text -> ServerError
    jsonErr e msg = e { errBody = A.encode (object ["error" .= msg])
                      , errHeaders = [(hContentType, "application/json")]
                      }

    requireAuth :: Maybe Text -> Handler (User, Text)
    requireAuth mc = do
      let mtok = mc >>= extractSession
      case mtok of
        Nothing -> throwError $ jsonErr err401 "Authentication required"
        Just tok -> do
          mu <- liftIO . atomically $ tokenToUser tok
          case mu of
            Nothing -> throwError $ jsonErr err401 "Authentication required"
            Just u -> pure (u, tok)

    extractSession :: Text -> Maybe Text
    extractSession cookieHeader =
      let bs = BS.pack (T.unpack cookieHeader)
          cs = parseCookies bs
      in fmap (T.pack . BS.unpack) (lookup "session_id" cs)

    tokenToUser :: Text -> STM (Maybe User)
    tokenToUser tok = do
      ss <- readTVar (sessions st)
      case lookup tok ss of
        Nothing -> pure Nothing
        Just uid -> do
          us <- readTVar (users st)
          pure $ iUser <$> findById uid us

    findById :: Int -> [IUser] -> Maybe IUser
    findById i = foldr (\u acc -> if userId (iUser u) == i then Just u else acc) Nothing

    validUsername :: Text -> Bool
    validUsername u =
      let l = T.length u
          allowed = T.pack (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "_")
      in l >= 3 && l <= 50 && T.all (\c -> T.any (== c) allowed) u

    isoNow :: IO Text
    isoNow = do
      t <- getCurrentTime
      let fmt = iso8601DateFormat (Just "%H:%M:%SZ")
      pure (T.pack (formatTime defaultTimeLocale fmt t))

    newSessionIO :: User -> IO Text
    newSessionIO u = do
      tok <- T.pack . UUID.toString <$> UUIDv4.nextRandom
      atomically $ do
        ss <- readTVar (sessions st)
        writeTVar (sessions st) ((tok, userId u) : ss)
      pure tok

    invalidateSession :: Text -> STM ()
    invalidateSession tok = do
      ss <- readTVar (sessions st)
      writeTVar (sessions st) (filter ((/= tok) . fst) ss)

    -- Handlers
    registerH :: RegisterReq -> Handler User
    registerH (RegisterReq uname pw) = do
      when (not (validUsername uname)) $ throwError $ jsonErr err400 "Invalid username"
      when (T.length pw < 8) $ throwError $ jsonErr err400 "Password too short"
      res <- liftIO . atomically $ do
        us <- readTVar (users st)
        if any ((== uname) . username . iUser) us
          then pure (Left ())
          else do
            i <- readTVar (nextUserId st)
            let u = User i uname
            writeTVar (nextUserId st) (i+1)
            writeTVar (users st) (us ++ [IUser u pw])
            pure (Right u)
      case res of
        Left _ -> throwError $ jsonErr err409 "Username already exists"
        Right u -> pure u

    loginH :: LoginReq -> Handler (Headers '[Header "Set-Cookie" String] User)
    loginH (LoginReq uname pw) = do
      mu <- liftIO . atomically $ do
        us <- readTVar (users st)
        pure $ find (\(IUser (User _ un) p) -> un == uname && p == pw) us
      case mu of
        Nothing -> throwError $ jsonErr err401 "Invalid credentials"
        Just (IUser u _) -> do
          tok <- liftIO $ newSessionIO u
          let sc = defaultSetCookie { setCookieName = "session_id"
                                    , setCookieValue = BS.pack (T.unpack tok)
                                    , setCookiePath = Just "/"
                                    , setCookieHttpOnly = True
                                    }
              setCookieHeader = BS.unpack . LBS.toStrict . BB.toLazyByteString $ renderSetCookie sc
          pure $ addHeader setCookieHeader u

    logoutH :: Maybe Text -> Handler A.Value
    logoutH mc = do
      (_u, tok) <- requireAuth mc
      liftIO . atomically $ invalidateSession tok
      pure (object [])

    meH :: Maybe Text -> Handler User
    meH mc = fst <$> requireAuth mc

    passH :: Maybe Text -> PasswordReq -> Handler A.Value
    passH mc (PasswordReq oldp newp) = do
      (u, _) <- requireAuth mc
      when (T.length newp < 8) $ throwError $ jsonErr err400 "Password too short"
      ok <- liftIO . atomically $ do
        us <- readTVar (users st)
        let ok' = case findById (userId u) us of
                    Just (IUser _ pw) -> pw == oldp
                    Nothing -> False
        when ok' $ do
          let us' = map (\iu@(IUser u' pw) -> if userId u' == userId u then IUser u newp else iu) us
          writeTVar (users st) us'
        pure ok'
      unless ok $ throwError $ jsonErr err401 "Invalid credentials"
      pure (object [])

    listH :: Maybe Text -> Handler [Todo]
    listH mc = do
      (u, _) <- requireAuth mc
      liftIO . atomically $ do
        ts <- readTVar (todos st)
        pure $ sortOn todoId [t | t <- ts, todoUserId t == userId u]

    createH :: Maybe Text -> CreateTodoReq -> Handler Todo
    createH mc (CreateTodoReq t md) = do
      (u, _) <- requireAuth mc
      when (T.strip t == "") $ throwError $ jsonErr err400 "Title is required"
      now <- liftIO isoNow
      liftIO . atomically $ do
        i <- readTVar (nextTodoId st)
        let todo = Todo i (userId u) t (fromMaybe "" md) False now now
        ts <- readTVar (todos st)
        writeTVar (todos st) (ts ++ [todo])
        writeTVar (nextTodoId st) (i+1)
        pure todo

    getH :: Maybe Text -> Int -> Handler Todo
    getH mc tid = do
      (u, _) <- requireAuth mc
      mt <- liftIO . atomically $ do
        ts <- readTVar (todos st)
        pure $ findT tid ts
      case mt of
        Nothing -> throwError $ jsonErr err404 "Todo not found"
        Just t -> if todoUserId t /= userId u
                    then throwError $ jsonErr err404 "Todo not found"
                    else pure t

    updateH :: Maybe Text -> Int -> UpdateTodoReq -> Handler Todo
    updateH mc tid (UpdateTodoReq mt md mcpl) = do
      (u, _) <- requireAuth mc
      when (maybe False (\t -> T.strip t == "") mt) $ throwError $ jsonErr err400 "Title is required"
      now <- liftIO isoNow
      mres <- liftIO . atomically $ do
        ts <- readTVar (todos st)
        case findT tid ts of
          Nothing -> pure Nothing
          Just old -> if todoUserId old /= userId u
                        then pure Nothing
                        else do
                          let t' = fromMaybe (title old) mt
                              d' = fromMaybe (description old) md
                              c' = fromMaybe (completed old) mcpl
                              new = old { title = t', description = d', completed = c', updatedAt = now }
                              ts' = map (\x -> if todoId x == tid then new else x) ts
                          writeTVar (todos st) ts'
                          pure (Just new)
      case mres of
        Nothing -> throwError $ jsonErr err404 "Todo not found"
        Just new -> pure new

    deleteH :: Maybe Text -> Int -> Handler NoContent
    deleteH mc tid = do
      (u, _) <- requireAuth mc
      ok <- liftIO . atomically $ do
        ts <- readTVar (todos st)
        case findT tid ts of
          Nothing -> pure False
          Just old -> if todoUserId old /= userId u
                        then pure False
                        else do
                          writeTVar (todos st) (filter ((/= tid) . todoId) ts)
                          pure True
      if ok then pure NoContent else throwError $ jsonErr err404 "Todo not found"

    findT :: Int -> [Todo] -> Maybe Todo
    findT i = foldr (\t acc -> if todoId t == i then Just t else acc) Nothing

-- Application
app :: Store -> Application
app st = serve (Proxy :: Proxy API) (server st)

main :: IO ()
main = do
  args <- getArgs
  let port = case args of
        ["--port", p] -> read p
        _ -> 3000 :: Int
  st <- mkStore
  let settings = setPort port $ setHost "0.0.0.0" defaultSettings
  runSettings settings (app st)
