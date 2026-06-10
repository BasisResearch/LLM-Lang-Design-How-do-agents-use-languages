{-# LANGUAGE OverloadedStrings #-}
import Web.Scotty
import Network.HTTP.Types.Status (status200, status401, status404, status400, status409, status500, status201, status204)
main = scotty 8080 $ do
  get "/test" $ do
    status status200
    text "ok"
