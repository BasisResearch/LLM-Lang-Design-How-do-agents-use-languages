{-# LANGUAGE OverloadedStrings #-}

-- This is a sample to see how to use Web.Cookie in scotty
import qualified Data.ByteString.Char8 as BS
import qualified Network.Wai as Wai
import Web.Scotty
import Web.Cookie
import Data.Maybe (listToMaybe)

main :: IO ()
main = scotty 8080 $ do
    get "/" $ do
        cookies <- allHeaders <$> request
        let cookieStr = BS.unpack =<< listToMaybe [v | (h, v) <- cookies, h == "cookie"]
        let parsedCookies = case cookieStr of
                Just cs -> parseCookies $ BS.pack cs
                Nothing -> mempty
        html $ "Cookies: " ++ show parsedCookies