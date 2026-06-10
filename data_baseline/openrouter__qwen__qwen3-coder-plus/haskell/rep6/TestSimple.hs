{-# LANGUAGE OverloadedStrings #-}

import Web.Scotty
import Data.Text.Lazy as L

main = scotty 3000 $ do
  get "/test/:id" $ do
    id_param <- param "id"
    html $ L.append "ID is: " id_param