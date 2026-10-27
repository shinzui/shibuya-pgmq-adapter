module Main (main) where

import Data.Aeson (Value (Null), encode)
import Data.ByteString.Lazy.Char8 qualified as LBS
import System.Environment (getArgs)
import WorkerPerformance (runWorker)

main :: IO ()
main = do
  [scenario, warmup, sample, seeds] <- getArgs
  runWorker scenario (read warmup) (read sample) (read seeds) (\_ _ -> pure (pure Null)) >>= LBS.putStrLn . encode
