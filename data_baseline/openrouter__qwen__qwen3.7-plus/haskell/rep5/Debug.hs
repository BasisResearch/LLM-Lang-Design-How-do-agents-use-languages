{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
import Data.Aeson
import GHC.Generics
import Data.Text (Text)
import qualified Data.ByteString.Lazy as BL

data RegisterReq = RegisterReq
  { rrUsername :: Text
  , rrPassword :: Text
  } deriving (Generic)

instance FromJSON RegisterReq

main :: IO ()
main = do
  let jsonStr = BL.fromStrict "{ \"username\": \"testuser\", \"password\": \"password123\" }"
  print (eitherDecode jsonStr :: Either String RegisterReq)
