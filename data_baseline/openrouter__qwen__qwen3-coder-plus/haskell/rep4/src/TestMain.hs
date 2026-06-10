{-# LANGUAGE OverloadedStrings #-}

-- Simple test to see if basic server builds
module Main where

import Web.Scotty
import qualified Network.HTTP.Types.Status as Status
import Data.Aeson (Value(..), object, (.=), encode, decode)
import Data.IORef
import qualified Data.ByteString.Char8 as C

main = scotty 3000 $ do
  get "/" $ do
    json $ object ["message" .= ("Hello World" :: String)]