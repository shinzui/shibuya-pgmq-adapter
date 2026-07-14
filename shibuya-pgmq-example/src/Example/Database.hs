-- | Database pool setup and queue creation for the PGMQ example.
module Example.Database
  ( -- * Pool Management
    withDatabasePool,
    createPool,

    -- * Queue Setup
    createQueues,
    installSchema,

    -- * Queue Names
    ordersQueueName,
    paymentsQueueName,
    notificationsQueueName,
    dlqOrdersQueueName,
    dlqPaymentsQueueName,
    backoffDemoQueueName,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate qualified as Migrate
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Migration qualified as Migration
import Pgmq.Types (QueueName, parseQueueName)

-- | Queue name for orders.
ordersQueueName :: QueueName
ordersQueueName = case parseQueueName "orders" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Queue name for payments.
paymentsQueueName :: QueueName
paymentsQueueName = case parseQueueName "payments" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Queue name for notifications.
notificationsQueueName :: QueueName
notificationsQueueName = case parseQueueName "notifications" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Dead-letter queue for orders.
dlqOrdersQueueName :: QueueName
dlqOrdersQueueName = case parseQueueName "dlq_orders" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Dead-letter queue for payments.
dlqPaymentsQueueName :: QueueName
dlqPaymentsQueueName = case parseQueueName "dlq_payments" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Queue used by the @backoff-demo@ subcommand of the consumer/simulator.
backoffDemoQueueName :: QueueName
backoffDemoQueueName = case parseQueueName "backoff_demo" of
  Left err -> error $ "Invalid queue name: " <> show err
  Right q -> q

-- | Hasql connection settings for a connection string.
connectionSettings :: ByteString -> Settings.Settings
connectionSettings connStr = Settings.connectionString (Text.pack (BS.unpack connStr))

-- | Create a connection pool.
createPool :: ByteString -> IO Pool.Pool
createPool connStr = do
  let connSettings = connectionSettings connStr
      poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 20,
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig

-- | Bracket pattern for pool lifecycle.
withDatabasePool :: ByteString -> (Pool.Pool -> IO a) -> IO a
withDatabasePool connStr action = do
  pool <- createPool connStr
  result <- action pool
  Pool.release pool
  pure result

-- | Install PGMQ schema and create all queues.
--
-- Takes the connection string as well as the pool because the migration runner
-- acquires its own connection (see 'installSchema').
createQueues :: ByteString -> Pool.Pool -> IO ()
createQueues connStr pool = do
  installSchema connStr
  createQueue pool ordersQueueName
  createQueue pool paymentsQueueName
  createQueue pool notificationsQueueName
  createQueue pool dlqOrdersQueueName
  createQueue pool dlqPaymentsQueueName
  createQueue pool backoffDemoQueueName

-- | Install the PGMQ schema.
--
-- pgmq-migration 0.4 replaced its own runner with a native pg-migrate
-- component: an application composes the component into a plan and runs the
-- plan. The runner takes connection settings rather than the application pool,
-- because it acquires its own connection to hold the migration advisory lock.
-- Running against an already-migrated database is a no-op.
--
-- This installs onto a fresh database. A database that still carries a pre-0.4
-- @public.schema_migrations@ ledger must have that history imported through
-- @Pgmq.Migration.History.HasqlMigration@ before the native runner takes over;
-- see the README.
installSchema :: ByteString -> IO ()
installSchema connStr = do
  component <- case Migration.pgmqMigrations of
    Left err -> error $ "pgmq migration definition error: " <> show err
    Right component -> pure component
  plan <- case Migrate.migrationPlan (component :| []) of
    Left err -> error $ "pgmq migration plan error: " <> show err
    Right plan -> pure plan
  result <- Migrate.runMigrationPlan Migrate.defaultRunOptions (connectionSettings connStr) plan
  case result of
    Left err -> error $ "Migration error: " <> show err
    Right _report -> pure ()

-- | Create a single queue (no-op if exists).
createQueue :: Pool.Pool -> QueueName -> IO ()
createQueue pool qName = do
  result <- Pool.use pool $ Pgmq.createQueue qName
  case result of
    Left err -> error $ "Create queue error: " <> show err
    Right _ -> pure ()
