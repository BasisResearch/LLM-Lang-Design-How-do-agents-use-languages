{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
module Main where

import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, setHost, setPort, runSettings)
import Network.HTTP.Types (status200, status201, status204, status400, status401, status404, status409, hContentType, hCookie)
import qualified Network.HTTP.Types as HT
import Data.Aeson (ToJSON, FromJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as M
import Data.Map.Strict (Map)
import Data.IORef
import Control.Monad.IO.Class ()
import Data.Time (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Generics (Generic)
import System.Environment (getArgs)
import Data.UUID.V4 (nextRandom)
import Data.UUID (toText)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BL
import Web.Cookie (parseCookies)
import Data.List (sortOn)
import Data.Char (isAlphaNum)
import qualified Data.Text.Read as TR

-- Data Types

data User = User { userId :: Int, username :: T.Text } deriving (Show, Eq, Generic)
instance ToJSON User where
  toJSON User{..} = A.object ["id" .= userId, "username" .= username]

-- Stored user record

data UserRec = UserRec { uUser :: User, uPassword :: T.Text } deriving (Show, Eq)

-- Todo

data Todo = Todo
  { todoId :: Int
  , todoTitle :: T.Text
  , todoDescription :: T.Text
  , todoCompleted :: Bool
  , todoCreatedAt :: T.Text
  , todoUpdatedAt :: T.Text
  , todoOwnerId :: Int
  } deriving (Show, Eq)

instance ToJSON Todo where
  toJSON Todo{..} = A.object
    [ "id" .= todoId
    , "title" .= todoTitle
    , "description" .= todoDescription
    , "completed" .= todoCompleted
    , "created_at" .= todoCreatedAt
    , "updated_at" .= todoUpdatedAt
    ]

-- Request bodies

data RegisterBody = RegisterBody { rbUsername :: T.Text, rbPassword :: T.Text } deriving (Show, Generic)
instance FromJSON RegisterBody where
  parseJSON = A.withObject "RegisterBody" $ \o -> RegisterBody <$> o A..: "username" <*> o A..: "password"

data LoginBody = LoginBody { lbUsername :: T.Text, lbPassword :: T.Text } deriving (Show, Generic)
instance FromJSON LoginBody where
  parseJSON = A.withObject "LoginBody" $ \o -> LoginBody <$> o A..: "username" <*> o A..: "password"

data PasswordBody = PasswordBody { oldPassword :: T.Text, newPassword :: T.Text } deriving (Show, Generic)
instance FromJSON PasswordBody where
  parseJSON = A.withObject "PasswordBody" $ \o -> PasswordBody <$> o A..: "old_password" <*> o A..: "new_password"

-- create todo body

data CreateTodoBody = CreateTodoBody { ctTitle :: T.Text, ctDescription :: Maybe T.Text } deriving (Show)
instance FromJSON CreateTodoBody where
  parseJSON = A.withObject "CreateTodoBody" $ \o -> CreateTodoBody <$> o A..: "title" <*> o A..:? "description"

-- update todo body (partial)

data UpdateTodoBody = UpdateTodoBody { utTitle :: Maybe T.Text, utDescription :: Maybe T.Text, utCompleted :: Maybe Bool } deriving (Show)
instance FromJSON UpdateTodoBody where
  parseJSON = A.withObject "UpdateTodoBody" $ \o -> UpdateTodoBody <$> o A..:? "title" <*> o A..:? "description" <*> o A..:? "completed"

-- Server State

data ServerState = ServerState
  { nextUserId :: Int
  , users :: Map Int UserRec
  , usersByName :: Map T.Text Int
  , nextTodoId :: Int
  , todos :: Map Int Todo
  , sessions :: Map T.Text Int -- token -> userId
  }

type AppState = IORef ServerState

emptyState :: ServerState
emptyState = ServerState 1 M.empty M.empty 1 M.empty M.empty

-- Utilities

jsonResponse :: HT.Status -> A.Value -> Response
jsonResponse st v = responseLBS st [(hContentType, "application/json")] (A.encode v)

jsonError :: HT.Status -> T.Text -> Response
jsonError st msg = jsonResponse st (A.object ["error" .= msg])

noContent :: Response
noContent = responseLBS status204 [] BL.empty

-- time formatting
formatIso :: IO T.Text
formatIso = do
  t <- getCurrentTime
  pure . T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t

-- Strictly read request body (since wai by default streams)
strictRequestBody' :: Request -> IO BL.ByteString
strictRequestBody' req = go mempty
  where
    go acc = do
      chunk <- getRequestBodyChunk req
      if BS.null chunk
        then pure (BL.fromStrict acc)
        else go (acc <> chunk)

-- get cookie by name from request headers
getCookieVal :: T.Text -> Request -> Maybe T.Text
getCookieVal name req = do
  cookieBs <- lookup hCookie (requestHeaders req)
  let cookies = parseCookies cookieBs -- [(key,val)] bytestrings
  v <- lookup (TE.encodeUtf8 name) cookies
  Just (TE.decodeUtf8 v)

-- require auth
requireAuth :: AppState -> Request -> IO (Either Response (UserRec, T.Text))
requireAuth st req = do
  case getCookieVal "session_id" req of
    Nothing -> pure $ Left (jsonError status401 "Authentication required")
    Just tok -> do
      s <- readIORef st
      case M.lookup tok (sessions s) of
        Nothing -> pure $ Left (jsonError status401 "Authentication required")
        Just uid -> case M.lookup uid (users s) of
          Nothing -> pure $ Left (jsonError status401 "Authentication required")
          Just ur -> pure $ Right (ur, tok)

-- validations
validUsername :: T.Text -> Bool
validUsername t = let l = T.length t in l >= 3 && l <= 50 && T.all (\c -> isAlphaNum c || c == '_') t

-- Router
app :: AppState -> Application
app st req respond = case (requestMethod req, pathInfo req) of
  ("POST", ["register"]) -> do
    bodyBs <- strictRequestBody' req
    case A.eitherDecode bodyBs of
      Left _ -> respond $ jsonError status400 "Invalid username"
      Right (RegisterBody uname pwd) ->
        if not (validUsername uname) then respond $ jsonError status400 "Invalid username"
        else if T.length pwd < 8 then respond $ jsonError status400 "Password too short"
        else do
          res <- atomicModifyIORef' st $ \s ->
            if M.member uname (usersByName s)
            then (s, Left ())
            else let uid = nextUserId s
                     u = User uid uname
                     ur = UserRec u pwd
                  in ( s{ nextUserId = uid + 1
                        , users = M.insert uid ur (users s)
                        , usersByName = M.insert uname uid (usersByName s)
                        }
                     , Right u)
          case res of
            Left _ -> respond $ jsonError status409 "Username already exists"
            Right u -> respond $ jsonResponse status201 (A.toJSON u)

  ("POST", ["login"]) -> do
    bodyBs <- strictRequestBody' req
    case A.eitherDecode bodyBs of
      Left _ -> respond $ jsonError status401 "Invalid credentials"
      Right (LoginBody uname pwd) -> do
        s <- readIORef st
        case M.lookup uname (usersByName s) >>= (\uid -> M.lookup uid (users s)) of
          Nothing -> respond $ jsonError status401 "Invalid credentials"
          Just (UserRec u upwd) ->
            if upwd /= pwd then respond $ jsonError status401 "Invalid credentials"
            else do
              token <- toText <$> nextRandom
              atomicModifyIORef' st $ \s' -> (s'{ sessions = M.insert token (userId u) (sessions s') }, ())
              respond $ responseLBS status200 [ (hContentType, "application/json")
                                              , ("Set-Cookie", TE.encodeUtf8 $ T.concat ["session_id=", token, "; Path=/; HttpOnly"]) ]
                                         (A.encode (A.toJSON u))

  ("POST", ["logout"]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (_, tok) -> do
        atomicModifyIORef' st $ \s -> (s{ sessions = M.delete tok (sessions s) }, ())
        respond $ jsonResponse status200 (A.object [])

  ("GET", ["me"]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (UserRec u _, _) -> respond $ jsonResponse status200 (A.toJSON u)

  ("PUT", ["password"]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (UserRec u oldPwd, _) -> do
        bodyBs <- strictRequestBody' req
        case A.eitherDecode bodyBs of
          Left _ -> respond $ jsonError status400 "Password too short"
          Right (PasswordBody op np) ->
            if op /= oldPwd then respond $ jsonError status401 "Invalid credentials"
            else if T.length np < 8 then respond $ jsonError status400 "Password too short"
            else do
              atomicModifyIORef' st $ \s -> (s{ users = M.adjust (\(UserRec uu _) -> UserRec uu np) (userId u) (users s) }, ())
              respond $ jsonResponse status200 (A.object [])

  ("GET", ["todos"]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (UserRec u _, _) -> do
        s <- readIORef st
        let ts = [ t | t <- M.elems (todos s), todoOwnerId t == userId u ]
            sorted = sortOn todoId ts
        respond $ jsonResponse status200 (A.toJSON sorted)

  ("POST", ["todos"]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (UserRec u _, _) -> do
        bodyBs <- strictRequestBody' req
        case A.eitherDecode bodyBs of
          Left _ -> respond $ jsonError status400 "Title is required"
          Right (CreateTodoBody ttl mdesc) ->
            if T.strip ttl == "" then respond $ jsonError status400 "Title is required"
            else do
              ts <- formatIso
              let desc = fromMaybe "" mdesc
              t' <- atomicModifyIORef' st $ \s ->
                let tid = nextTodoId s
                    todo = Todo tid ttl desc False ts ts (userId u)
                 in (s{ nextTodoId = tid + 1, todos = M.insert tid todo (todos s) }, todo)
              respond $ jsonResponse status201 (A.toJSON t')

  ("GET", ["todos", tidTxt]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (UserRec u _, _) -> do
        case parseId tidTxt of
          Nothing -> respond $ jsonError status404 "Todo not found"
          Just tid -> do
            s <- readIORef st
            case M.lookup tid (todos s) of
              Just t | todoOwnerId t == userId u -> respond $ jsonResponse status200 (A.toJSON t)
              _ -> respond $ jsonError status404 "Todo not found"

  ("PUT", ["todos", tidTxt]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (UserRec u _, _) -> do
        case parseId tidTxt of
          Nothing -> respond $ jsonError status404 "Todo not found"
          Just tid -> do
            bodyBs <- strictRequestBody' req
            case A.eitherDecode bodyBs of
              Left _ -> respond $ jsonError status400 "Title is required"
              Right (UpdateTodoBody mt md mc) ->
                if maybe False (\x -> T.strip x == "") mt then respond $ jsonError status400 "Title is required"
                else do
                  now <- formatIso
                  res <- atomicModifyIORef' st $ \s ->
                    case M.lookup tid (todos s) of
                      Nothing -> (s, Left ())
                      Just t -> if todoOwnerId t /= userId u
                                then (s, Left ())
                                else let newT = t { todoTitle = fromMaybe (todoTitle t) mt
                                                  , todoDescription = fromMaybe (todoDescription t) md
                                                  , todoCompleted = fromMaybe (todoCompleted t) mc
                                                  , todoUpdatedAt = now }
                                         s' = s { todos = M.insert tid newT (todos s) }
                                      in (s', Right newT)
                  case res of
                    Left _ -> respond $ jsonError status404 "Todo not found"
                    Right t' -> respond $ jsonResponse status200 (A.toJSON t')

  ("DELETE", ["todos", tidTxt]) -> do
    auth <- requireAuth st req
    case auth of
      Left r -> respond r
      Right (UserRec u _, _) -> do
        case parseId tidTxt of
          Nothing -> respond $ jsonError status404 "Todo not found"
          Just tid -> do
            res <- atomicModifyIORef' st $ \s ->
              case M.lookup tid (todos s) of
                Nothing -> (s, Left ())
                Just t -> if todoOwnerId t /= userId u
                          then (s, Left ())
                          else (s{ todos = M.delete tid (todos s) }, Right ())
            case res of
              Left _ -> respond $ jsonError status404 "Todo not found"
              Right () -> respond noContent

  _ -> respond $ jsonError status404 "Not found"
  where
    parseId :: T.Text -> Maybe Int
    parseId t = case TR.decimal t of
      Right (n, rest) | T.null rest -> Just n
      _ -> Nothing

buildApp :: Int -> IO Application
buildApp _port = do
  st <- newIORef emptyState
  pure (app st)

main :: IO ()
main = do
  args <- getArgs
  port <- case args of
    ["--port", p] -> case TR.decimal (T.pack p) of Right (n,_) -> pure n; _ -> fail "Invalid port"
    _ -> pure 3000
  application <- buildApp port
  let settings = setHost "0.0.0.0" $ setPort port defaultSettings
  runSettings settings application
