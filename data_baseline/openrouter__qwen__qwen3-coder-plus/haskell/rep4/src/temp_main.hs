{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Web.Scotty
import qualified Network.HTTP.Types.Status as HTTPStatus
import qualified Network.HTTP.Types.Header as HTTPHeader  
import qualified Network.Wai as Wai
import Data.Aeson (encode, decode, toJSON, object, (.=), FromJSON(parseJSON), ToJSON(toJSON), withObject, Value(Object), (.:), (.:?), (.!=))
import qualified Data.Text.Lazy as T
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

-- Define types...
