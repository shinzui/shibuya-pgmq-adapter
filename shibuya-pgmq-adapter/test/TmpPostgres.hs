-- | Temporary PostgreSQL setup for integration tests.
--
-- Uses ephemeral-pg to create an ephemeral PostgreSQL instance
-- and pgmq-migration to install the pgmq schema.
module TmpPostgres
  ( -- * Test Execution
    withPgmqDb,
    withTestFixture,

    -- * Test Fixture
    TestFixture (..),

    -- * Utilities
    runPgmqSession,
  )
where

import Control.Exception (bracket)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (secondsToDiffTime)
import Data.Word (Word64)
import Database.PostgreSQL.Migrate qualified as Migrate
import EphemeralPg (StartError, connectionSettings, with)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session (Session)
import Numeric (showHex)
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Migration qualified as Migration
import Pgmq.Types (QueueName, parseQueueName)
import System.Random (randomIO)

-- | Test fixture containing pool and queue names for a test
data TestFixture = TestFixture
  { pool :: !Pool.Pool,
    queueName :: !QueueName,
    dlqName :: !QueueName
  }

-- | Run an action with a temporary PostgreSQL database with pgmq schema installed.
--
-- This creates an ephemeral PostgreSQL instance, installs the pgmq schema,
-- and then runs the provided action with a connection pool.
withPgmqDb :: (Pool.Pool -> IO a) -> IO (Either StartError a)
withPgmqDb action = with $ \db -> do
  let connSettings = connectionSettings db

  -- Install pgmq schema
  installPgmqSchema connSettings

  -- Create and use connection pool
  bracket
    (createPool connSettings)
    Pool.release
    action

-- | Run an action with a test fixture (pool + unique queue names).
--
-- Creates unique queue names for each test to avoid collisions,
-- creates the queues, runs the test, then cleans up.
withTestFixture :: Pool.Pool -> (TestFixture -> IO a) -> IO a
withTestFixture pool action = do
  -- Generate unique queue names
  suffix <- randomSuffix
  let qName = case parseQueueName $ "test_" <> suffix of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      dlqName = case parseQueueName $ "test_dlq_" <> suffix of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e

  -- Create queues
  runPgmqSession pool $ do
    Pgmq.createQueue qName
    Pgmq.createQueue dlqName

  -- Run test
  result <- action TestFixture {pool, queueName = qName, dlqName}

  -- Cleanup queues
  runPgmqSession pool $ do
    _ <- Pgmq.dropQueue qName
    _ <- Pgmq.dropQueue dlqName
    pure ()

  pure result
  where
    randomSuffix :: IO Text
    randomSuffix = do
      uuid <- randomIO :: IO Word64
      pure $ Text.pack $ showHex uuid ""

-- | Run a hasql Session against the pool, throwing on error.
runPgmqSession :: Pool.Pool -> Session a -> IO a
runPgmqSession pool session = do
  result <- Pool.use pool session
  case result of
    Left err -> error $ "Session error: " <> show err
    Right a -> pure a

-- | Install pgmq schema into a PostgreSQL database.
--
-- The database is always fresh, so the native pg-migrate runner applies the
-- pgmq component from scratch; no predecessor ledger import is involved.
installPgmqSchema :: Settings.Settings -> IO ()
installPgmqSchema connSettings = do
  component <- case Migration.pgmqMigrations of
    Left defErr -> error $ "pgmq migration definition error: " <> show defErr
    Right component -> pure component
  plan <- case Migrate.migrationPlan (component :| []) of
    Left planErr -> error $ "pgmq migration plan error: " <> show planErr
    Right plan -> pure plan
  result <- Migrate.runMigrationPlan Migrate.defaultRunOptions connSettings plan
  case result of
    Left migrationErr -> error $ "Migration error: " <> show migrationErr
    Right _report -> pure ()

-- | Create a connection pool from connection settings.
createPool :: Settings.Settings -> IO Pool.Pool
createPool connSettings = do
  let poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 10,
            PoolConfig.acquisitionTimeout (secondsToDiffTime 10),
            PoolConfig.agingTimeout (secondsToDiffTime 3600),
            PoolConfig.idlenessTimeout (secondsToDiffTime 60),
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig
