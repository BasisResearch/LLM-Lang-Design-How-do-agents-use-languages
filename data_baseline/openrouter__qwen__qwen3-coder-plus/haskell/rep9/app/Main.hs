module Main where

import System.Environment (getArgs, getProgName, withArgs)
import Options.Applicative
import Data.Semigroup ((<>))

-- Options parsing
data Options = Options
  { optPort :: Int
  } deriving (Show)

optionsParser :: Parser Options
optionsParser = Options
  <$> option auto
      ( long "port"
     <> short 'p'
     <> metavar "PORT"
     <> help "Port number to listen on"
     <> value 3000
     <> showDefault )

main :: IO ()
main = do
    opts <- execParser $
               info (optionsParser <**> helper)
               (fullDesc <> progDesc "Start todo app server" <> header "Todo App Server")
    putStrLn $ "Starting server on port: " ++ show (optPort opts)
    args' <- getArgs
    progName <- getProgName
    -- Pass the port to actual server code in Lib
    import qualified Lib
    Lib.startServer (optPort opts)