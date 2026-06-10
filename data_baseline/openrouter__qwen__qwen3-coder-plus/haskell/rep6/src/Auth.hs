{-# LANGUAGE OverloadedStrings #-}

module Auth where

import Data.Char (isAlphaNum)
import System.Random
import Control.Monad.IO.Class (liftIO)

-- Generate a secure random session ID
generateSessionId :: IO String
generateSessionId = do
  gen <- newStdGen
  let randomValues = take 32 $ randomRs ('a','z') gen  -- 32 chars from a-z
  return randomValues

-- Validate username format
validateUsername :: String -> Bool
validateUsername username = 
  length username >= 3 && 
  length username <= 50 && 
  all (\c -> isAlphaNum c || c == '_') username

-- Validate password length
validatePassword :: String -> Bool
validatePassword pwd = length pwd >= 8