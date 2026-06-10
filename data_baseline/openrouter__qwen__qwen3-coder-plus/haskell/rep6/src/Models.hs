{-# LANGUAGE OverloadedStrings #-}

module Models where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Types
import Control.Concurrent.STM
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Time.Clock
import Data.List (sortBy)


createTodoWithTime :: Int -> String -> String -> UTCTime -> StorageState -> STM (Maybe Todo)
createTodoWithTime userId title desc time storage = do
  nextId <- getNextTodoId storage
  let newTodo = Todo 
        { todoId = nextId
        , title = title
        , description = desc
        , completed = False
        , createdAt = time
        , updatedAt = time
        }
  
  todoMap <- readTVar $ todos storage
  writeTVar (todos storage) (Map.insert nextId (userId, newTodo) todoMap)
  return $ Just newTodo


-- Wrapper to use IO time functions  
createTodo :: Int -> String -> String -> StorageState -> IO (Maybe Todo)  
createTodo userId title desc storage = do
  time <- getCurrentTime
  result <- atomically $ createTodoWithTime userId title desc time storage
  return result

updateTodoWithTime :: Int -> Int -> UpdateTodoRequest -> UTCTime -> StorageState -> STM (Maybe Todo)
updateTodoWithTime userId todoId req time storage = do
  mTodoData <- getTodoById todoId storage
  case mTodoData of
    Nothing -> return Nothing
    Just (ownerId, oldTodo) -> 
      if ownerId /= userId
        then return Nothing
        else do
          let newTitle = fromMaybe (title oldTodo) (updateTitle req)
          let newDesc = fromMaybe (description oldTodo) (updateDescription req)
          
          -- Validate title if provided
          if updateTitle req /= Nothing && null newTitle
            then return Nothing
            else do
              let newCompleted = fromMaybe (completed oldTodo) (updateCompleted req)
                  updatedTodo = oldTodo 
                    { title = newTitle
                    , description = newDesc
                    , completed = newCompleted
                    , updatedAt = time
                    }
              
              -- Update the todo in storage
              todoMap <- readTVar $ todos storage
              writeTVar (todos storage) (Map.insert todoId (userId, updatedTodo) todoMap)
              return $ Just updatedTodo

-- Wrapper to update Todo with time
updateTodo :: Int -> Int -> UpdateTodoRequest -> StorageState -> IO (Maybe Todo)
updateTodo userId todoId req storage = do
  time <- getCurrentTime
  result <- atomically $ updateTodoWithTime userId todoId req time storage
  return result


data StorageState = StorageState
  { users :: TVar (Map.Map String User) -- Maps usernames to Users
  , userIdCounter :: TVar Int
  , todos :: TVar (Map.Map Int (Int, Todo)) -- Maps todoId to (userId, todo)
  , todoIdCounter :: TVar Int
  , sessions :: TVar (Map.Map String Int) -- Maps sessionId to userId
  , passwords :: TVar (Map.Map Int String) -- Maps userId to encrypted password hash
  }

initStorage :: IO StorageState
initStorage = do
  usersVar <- newTVarIO Map.empty
  userIdCounterVar <- newTVarIO 0
  todosVar <- newTVarIO Map.empty
  todoIdCounterVar <- newTVarIO 0
  sessionsVar <- newTVarIO Map.empty
  passwordsVar <- newTVarIO Map.empty
  
  return $ StorageState 
    { users = usersVar
    , userIdCounter = userIdCounterVar
    , todos = todosVar
    , todoIdCounter = todoIdCounterVar
    , sessions = sessionsVar
    , passwords = passwordsVar
    }

getNextUserId :: StorageState -> STM Int
getNextUserId storage = do
  counter <- readTVar $ userIdCounter storage
  writeTVar (userIdCounter storage) (counter + 1)
  return (counter + 1)

getNextTodoId :: StorageState -> STM Int
getNextTodoId storage = do
  counter <- readTVar $ todoIdCounter storage
  writeTVar (todoIdCounter storage) (counter + 1)
  return (counter + 1)

getUserByUsername :: String -> StorageState -> STM (Maybe User)
getUserByUsername uname storage = do
  userMap <- readTVar $ users storage
  return $ Map.lookup uname userMap

createUser :: String -> String -> StorageState -> STM (Maybe User)
createUser uname pwd storage = do
  existingUser <- getUserByUsername uname storage
  case existingUser of
    Just _ -> return Nothing
    Nothing -> do
      nextId <- getNextUserId storage
      let newUser = User nextId uname
      userMap <- readTVar $ users storage
      writeTVar (users storage) (Map.insert uname newUser userMap)
      passMap <- readTVar $ passwords storage
      writeTVar (passwords storage) (Map.insert nextId pwd passMap)
      return $ Just newUser

validateUser :: String -> String -> StorageState -> STM (Maybe Int)
validateUser uname pwd storage = do
  mUser <- getUserByUsername uname storage
  case mUser of
    Nothing -> return Nothing
    Just user -> do
      passMap <- readTVar $ passwords storage
      case Map.lookup (userId user) passMap of
        Just storedPwd -> if pwd == storedPwd 
                            then return $ Just (userId user)
                            else return Nothing
        Nothing -> return Nothing

getTodosByUser :: Int -> StorageState -> STM [Todo]
getTodosByUser uid storage = do
  todoMap <- readTVar $ todos storage
  let userTodos = filter (\(_, (todoUserId, _)) -> todoUserId == uid) (Map.assocs todoMap)
  let todosWithoutKeys = map (\(_, (_, todo)) -> todo) userTodos
  -- Sort by id ascending as required by specification
  return $ sortBy (\a b -> compare (todoId a) (todoId b)) todosWithoutKeys 

updatePassword :: Int -> String -> String -> StorageState -> STM Bool
updatePassword uid oldPw newPw storage = do
  passMap <- readTVar $ passwords storage
  case Map.lookup uid passMap of
    Just storedPwd -> if oldPw == storedPwd
                        then do
                          writeTVar (passwords storage) (Map.insert uid newPw passMap)
                          return True
                        else return False
    Nothing -> return False

getTodoById :: Int -> StorageState -> STM (Maybe (Int, Todo))
getTodoById tid storage = do
  todoMap <- readTVar $ todos storage
  return $ Map.lookup tid todoMap

deleteTodo :: Int -> Int -> StorageState -> STM Bool
deleteTodo userId todoId storage = do
  mTodoData <- getTodoById todoId storage
  case mTodoData of
    Nothing -> return False
    Just (ownerId, _) -> 
      if ownerId /= userId
        then return False
        else do
          todoMap <- readTVar $ todos storage
          writeTVar (todos storage) (Map.delete todoId todoMap)
          return True

addSession :: String -> Int -> StorageState -> STM ()
addSession sessionId userId storage = do
  sessionMap <- readTVar $ sessions storage
  writeTVar (sessions storage) (Map.insert sessionId userId sessionMap)

findSessionUser :: String -> StorageState -> STM (Maybe Int)
findSessionUser sessionId storage = do
  sessionMap <- readTVar $ sessions storage
  return $ Map.lookup sessionId sessionMap

removeSession :: String -> StorageState -> STM Bool
removeSession sessionId storage = do
  sessionMap <- readTVar $ sessions storage
  if Map.member sessionId sessionMap
    then do
      writeTVar (sessions storage) (Map.delete sessionId sessionMap)
      return True
    else return False