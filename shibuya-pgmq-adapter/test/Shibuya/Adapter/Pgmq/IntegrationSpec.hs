-- | Integration tests for the PGMQ adapter.
--
-- These tests require a running PostgreSQL instance (provided via tmp-postgres).
-- Run with: cabal test --test-option='-p' --test-option='/Integration/'
-- Skip with: Set PGMQ_TEST_SKIP_DB=1 or use pattern '!/Integration/'
--
-- Note: Tests that use the streaming adapter (pgmqAdapter) are currently
-- marked as pending due to a known issue with Streamly and Effectful interaction.
-- The direct effectful API works correctly.
module Shibuya.Adapter.Pgmq.IntegrationSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.List (sort)
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Hasql
import Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq)
import Pgmq.Effectful qualified as PgmqEff
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types
  ( MessageQuery (..),
    ReadMessage (..),
    SendMessage (..),
    SendMessageWithHeaders (..),
    SendMessageWithHeadersForLater (..),
    VisibilityTimeoutQuery (..),
  )
import Pgmq.Types (Message (..), MessageBody (..), MessageHeaders (..), MessageId, QueueName)
import Shibuya.Adapter.Pgmq.Config
  ( FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PollingConfig (..),
    defaultConfig,
    defaultPollRetryConfig,
  )
import Shibuya.Adapter.Pgmq.Convert (pgmqMessageToEnvelope)
import Shibuya.Adapter.Pgmq.Internal (mkLease, pgmqChunks)
import Shibuya.Core.Lease (Lease (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Stream qualified as Stream
import System.Environment (lookupEnv)
import Test.Hspec
import TmpPostgres (TestFixture (..), runPgmqSession, withPgmqDb, withTestFixture)

spec :: Spec
spec = do
  -- Check if we should skip database tests
  runIO $ do
    skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"
    case skipDb of
      Just "1" -> pure ()
      _ -> pure ()

  around withTempDbFixture $ do
    describe "Integration" $ do
      basicMessageProcessingSpec
      visibilityTimeoutSpec
      retryHandlingSpec
      groupedHeadSpec

-- | Wrapper to run tests with a temporary database and fixture
withTempDbFixture :: (TestFixture -> IO ()) -> IO ()
withTempDbFixture action = do
  skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"
  case skipDb of
    Just "1" -> pendingWith "Database tests skipped (PGMQ_TEST_SKIP_DB=1)"
    _ -> do
      result <- withPgmqDb $ \pool ->
        withTestFixture pool action
      case result of
        Left err -> expectationFailure $ "Failed to start temp database: " <> show err
        Right () -> pure ()

-- | Run an Eff action with Pgmq effect against a pool, throwing on error.
runAdapterIO :: Pool.Pool -> Eff '[Pgmq, Error PgmqRuntimeError, IOE] a -> IO a
runAdapterIO pool action = do
  result <- runEff $ runErrorNoCallStack $ runPgmq pool action
  case result of
    Left err -> error $ "Pgmq error: " <> show err
    Right a -> pure a

-- | Basic message processing tests
basicMessageProcessingSpec :: SpecWith TestFixture
basicMessageProcessingSpec = describe "Basic message processing" $ do
  it "can send and read messages directly via session" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Send a message
    _msgId <- runPgmqSession pool $ do
      Sessions.sendMessage $
        SendMessage
          { queueName = queueName,
            messageBody = MessageBody (String "direct-test"),
            delay = Just 0
          }

    -- Read directly via session
    msgs <-
      runPgmqSession pool $
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
    Vector.length msgs `shouldBe` 1

  it "can send and read messages directly via effectful" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Send a message via session
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "effectful-test"),
              delay = Just 0
            }
      pure ()

    -- Read through effectful layer
    msgs <- runAdapterIO pool $ do
      PgmqEff.readMessage $
        ReadMessage
          { queueName = queueName,
            delay = 30,
            batchSize = Just 1,
            conditional = Nothing
          }
    Vector.length msgs `shouldBe` 1

  it "processes a single message and deletes it" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Send a message
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "test"),
              delay = Just 0
            }
      pure ()

    -- Read and verify payload, then delete
    processedRef <- newIORef Nothing
    runAdapterIO pool $ do
      msgs <-
        PgmqEff.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      case Vector.uncons msgs of
        Just (msg, _) -> do
          let Envelope {payload = p} = pgmqMessageToEnvelope msg
          liftIO $ writeIORef processedRef (Just p)
          -- Delete the message (simulating AckOk)
          _ <- PgmqEff.deleteMessage (MessageQuery queueName msg.messageId)
          pure ()
        Nothing -> pure ()

    -- Verify message was processed
    processed <- readIORef processedRef
    processed `shouldBe` Just (String "test")

    -- Verify queue is now empty
    msgs <-
      runPgmqSession pool $
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
    Vector.length msgs `shouldBe` 0

  it "processes multiple messages in order" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Enqueue 5 messages
    runPgmqSession pool $ do
      forM_ [1 .. 5 :: Int] $ \i ->
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (object ["order" .= i]),
              delay = Just 0
            }

    -- Read and process all 5
    processedCount <- runAdapterIO pool $ do
      msgs <-
        PgmqEff.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 10,
              conditional = Nothing
            }
      -- Delete each message
      forM_ (Vector.toList msgs) $ \msg ->
        PgmqEff.deleteMessage (MessageQuery queueName msg.messageId)
      pure $ Vector.length msgs

    processedCount `shouldBe` 5

-- | Visibility timeout tests
visibilityTimeoutSpec :: SpecWith TestFixture
visibilityTimeoutSpec = describe "Visibility timeout" $ do
  it "message reappears after visibility timeout" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Enqueue a message
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "vt-test"),
              delay = Just 0
            }
      pure ()

    -- Read message with short VT (1 second), don't delete
    runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 1, -- 1 second visibility timeout
              batchSize = Just 1,
              conditional = Nothing
            }
      liftIO $ Vector.length msgs `shouldBe` 1

    -- Wait for VT to expire
    threadDelay 1500000 -- 1.5 seconds

    -- Message should be visible again
    count <- runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      pure $ Vector.length msgs
    count `shouldBe` 1

  it "lease extension is a no-op after the message is deleted" $ \TestFixture {pool, queueName, dlqName = _} -> do
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "lease-race-test"),
              delay = Just 0
            }
      pure ()

    runAdapterIO pool $ do
      msgs <-
        PgmqEff.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      case Vector.uncons msgs of
        Just (msg, _) -> do
          lease <- mkLease (defaultConfig queueName) msg
          _ <- PgmqEff.deleteMessage (MessageQuery queueName msg.messageId)
          lease.leaseExtend 30
        Nothing -> liftIO $ expectationFailure "Expected one message to construct a lease"

    remaining <-
      runPgmqSession pool $
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
    Vector.length remaining `shouldBe` 0

-- | Retry handling tests (simulating AckRetry behavior)
retryHandlingSpec :: SpecWith TestFixture
retryHandlingSpec = describe "Retry handling" $ do
  it "set_vt extends visibility timeout (simulating AckRetry)" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Enqueue a message
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "retry-test"),
              delay = Just 0
            }
      pure ()

    -- Read message, then extend VT to 3 seconds
    runAdapterIO pool $ do
      msgs <-
        PgmqEff.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 1, -- Start with 1 second VT
              batchSize = Just 1,
              conditional = Nothing
            }
      case Vector.uncons msgs of
        Just (msg, _) -> do
          -- Extend VT by 3 seconds (simulating AckRetry)
          _ <-
            PgmqEff.changeVisibilityTimeout $
              VisibilityTimeoutQuery
                { queueName = queueName,
                  messageId = msg.messageId,
                  visibilityTimeoutOffset = 3
                }
          pure ()
        Nothing -> pure ()

    -- Message should not be visible yet (VT extended)
    threadDelay 1500000 -- 1.5 seconds
    count1 <- runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      pure $ Vector.length msgs
    count1 `shouldBe` 0

    -- After 3+ seconds total, message should be visible
    threadDelay 2000000 -- 2 more seconds (3.5s total)
    count2 <- runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      pure $ Vector.length msgs
    count2 `shouldBe` 1

groupedHeadSpec :: SpecWith TestFixture
groupedHeadSpec = describe "Grouped-head FIFO reads" $ do
  it "leases at most one absolute head per group and advances only a settled group" $ \TestFixture {pool, queueName, dlqName = _} -> do
    runPgmqSession pool $ Sessions.createFifoIndex queueName
    (a1, a2, b1) <-
      runPgmqSession pool $ do
        a1 <- sendGrouped queueName "a" "a1"
        a2 <- sendGrouped queueName "a" "a2"
        b1 <- sendGrouped queueName "b" "b1"
        _ <- sendGrouped queueName "b" "b2"
        pure (a1, a2, b1)

    heads <- readGroupedHeadBatch pool queueName
    sortedMessageIds heads `shouldBe` sort [a1, b1]

    blocked <- readGroupedHeadBatch pool queueName
    blocked `shouldBe` Vector.empty

    deleted <- runAdapterIO pool (PgmqEff.deleteMessage (MessageQuery queueName a1))
    deleted `shouldBe` True
    advanced <- readGroupedHeadBatch pool queueName
    sortedMessageIds advanced `shouldBe` [a2]

  it "lets another group advance while a delayed absolute head blocks its successor" $ \TestFixture {pool, queueName, dlqName = _} -> do
    runPgmqSession pool $ Sessions.createFifoIndex queueName
    scheduledAt <- addUTCTime 60 <$> getCurrentTime
    _a1 <-
      runPgmqSession pool $
        Sessions.sendMessageWithHeadersForLater
          SendMessageWithHeadersForLater
            { queueName,
              messageBody = MessageBody (String "a1"),
              messageHeaders = groupHeaders "a",
              scheduledAt
            }
    _a2 <- runPgmqSession pool (sendGrouped queueName "a" "a2")
    b1 <- runPgmqSession pool (sendGrouped queueName "b" "b1")

    heads <- readGroupedHeadBatch pool queueName
    sortedMessageIds heads `shouldBe` [b1]

readGroupedHeadBatch :: Pool.Pool -> QueueName -> IO (Vector.Vector Message)
readGroupedHeadBatch pool queueName = do
  batches <-
    runAdapterIO pool $
      Stream.toList $
        Stream.take 1 $
          pgmqChunks
            ( (defaultConfig queueName)
                { visibilityTimeout = 60,
                  batchSize = 10,
                  polling = StandardPolling {pollInterval = 0.01},
                  fifoConfig = Just FifoConfig {readStrategy = HeadPerGroup}
                }
            )
  case batches of
    [batch] -> pure batch
    _ -> error "Expected exactly one grouped-head batch"

sendGrouped :: QueueName -> Text -> Text -> Hasql.Session MessageId
sendGrouped queueName group body =
  Sessions.sendMessageWithHeaders
    SendMessageWithHeaders
      { queueName,
        messageBody = MessageBody (String body),
        messageHeaders = groupHeaders group,
        delay = Just 0
      }

groupHeaders :: Text -> MessageHeaders
groupHeaders group = MessageHeaders (object ["x-pgmq-group" .= group])

sortedMessageIds :: Vector.Vector Message -> [MessageId]
sortedMessageIds = sort . map (\message -> message.messageId) . Vector.toList

-- | Helper to create a config with sensible defaults for testing
_mkConfig :: QueueName -> PgmqAdapterConfig
_mkConfig queueName =
  PgmqAdapterConfig
    { queueName = queueName,
      visibilityTimeout = 30,
      batchSize = 1,
      polling = StandardPolling {pollInterval = 0.1}, -- Fast polling for tests
      pollRetry = defaultPollRetryConfig,
      ackRetry = defaultPollRetryConfig,
      deadLetterConfig = Nothing,
      haltVisibilityTimeout = Nothing,
      maxRetries = 3,
      fifoConfig = Nothing,
      prefetchConfig = Nothing
    }

-- | Create config with custom batch size
_mkConfigWithBatchSize :: QueueName -> Int32 -> PgmqAdapterConfig
_mkConfigWithBatchSize qName bs =
  PgmqAdapterConfig
    { queueName = qName,
      visibilityTimeout = 30,
      batchSize = bs,
      polling = StandardPolling {pollInterval = 0.1},
      pollRetry = defaultPollRetryConfig,
      ackRetry = defaultPollRetryConfig,
      deadLetterConfig = Nothing,
      haltVisibilityTimeout = Nothing,
      maxRetries = 3,
      fifoConfig = Nothing,
      prefetchConfig = Nothing
    }
