{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBSC
import Web.Scotty
import Web.Cookie (parseCookies)
import qualified Data.Aeson.KeyMap as MK

main = scotty 3000 $ do
    get "/" $ do
        cookieHdr <- header "Cookie"
        case cookieHdr of
            Nothing -> html "No cookie"
            Just bs -> do
                let cookieParsed = parseCookies $ LBSC.fromStrict bs
                html $ "Cookie: " ++ show (MK.toList cookieParsed)