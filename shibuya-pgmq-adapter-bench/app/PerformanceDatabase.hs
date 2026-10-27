-- | Disposable benchmark database. Setup and schema installation are untimed.
module PerformanceDatabase (withPgmqDb, withPgmqPools, runPgmqSession) where

import Control.Exception (bracket)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Monoid qualified as EphemeralMonoid
import Data.Time (secondsToDiffTime)
import Database.PostgreSQL.Migrate qualified as Migrate
import EphemeralPg (StartError)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session (Session)
import Pgmq.Migration qualified as Migration
import System.Directory qualified as EphemeralDirectory
import System.Posix.User qualified as EphemeralUser

withPgmqDb :: (Pool.Pool -> IO a) -> IO (Either StartError a)
withPgmqDb action = withPgmqPools (\pool _ -> action pool)

-- | Separate four-connection worker and two-connection administration pools.
withPgmqPools :: (Pool.Pool -> Pool.Pool -> IO a) -> IO (Either StartError a)
withPgmqPools action = withEphemeralPg $ \db -> do
  let connSettings = Pg.connectionSettings db
  installPgmqSchema connSettings
  bracket (createPool 4 connSettings) Pool.release $ \workers ->
    bracket (createPool 2 connSettings) Pool.release (action workers)

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
createPool :: Int -> Settings.Settings -> IO Pool.Pool
createPool size connSettings = do
  let poolConfig =
        PoolConfig.settings
          [ PoolConfig.size size,
            PoolConfig.acquisitionTimeout (secondsToDiffTime 10),
            PoolConfig.agingTimeout (secondsToDiffTime 3600),
            PoolConfig.idlenessTimeout (secondsToDiffTime 60),
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig

-- | Stable per-user root lets the next invocation reap abandoned clusters.
-- See mori://shinzui/ephemeral-pg/docs/guides (temporary-roots-and-stale-cleanup.md; artifact URI pending).
withEphemeralPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)
withEphemeralPg action = do
  uid <- EphemeralUser.getEffectiveUserID
  let root = "/tmp/ephpg-shibuya-dlq-performance-" <> show uid
  EphemeralDirectory.createDirectoryIfMissing True root
  let config = Pg.defaultConfig {Pg.temporaryRoot = EphemeralMonoid.Last (Just root)}
  Pg.withConfig config action
