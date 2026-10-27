-- | Candidate-only measurements. All databases are disposable; no connection
-- string is accepted. Raw controls use identical pools and transaction deadlines.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.DeepSeq (force)
import Control.Exception (bracket_, evaluate)
import Control.Monad (forM, forM_, replicateM, unless, void)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.IORef
import Data.List (sort)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (allocated_bytes, gc, gcdetails_live_bytes, getRTSStats, max_live_bytes)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Hasql.Statement qualified as St
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TS
import PerformanceDatabase (runPgmqSession, withPgmqDb)
import Pgmq.Hasql.Sessions qualified as Q
import Pgmq.Hasql.Statements.Inspection qualified as Inspection
import Pgmq.Types qualified as P
import Shibuya.Adapter.Pgmq.Convert (mkDlqPayload, mkDlqPayloadForQueue)
import Shibuya.Adapter.Pgmq.DeadLetter
import Shibuya.Core.Ack (DeadLetterReason (..), mkDeadLetterCode)
import System.Environment (getArgs)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import WorkerPerformance (runWorker)

main :: IO ()
main = do
  args <- getArgs
  result <- case args of
    ["worker", scenario, warm, sample, seeds, mode] ->
      runWorker scenario (read warm) (read sample) (read seeds) (prepareAdmin mode (read sample))
    ["reads", layout, depth, bytes, mode, warm, sample] ->
      db $ \pool -> readMatrix pool layout (read depth) (read bytes) mode (read warm) (read sample)
    ["retention", seconds] -> db $ \pool -> retention pool (read seconds)
    ["encoding", mode, warm, seconds] -> encodingMatrix mode (read warm) (read seconds)
    _ -> error "expected worker/reads/retention/encoding arguments"
  LBC.putStrLn (encode result)

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

source, dlq :: P.QueueName
source = checked (P.parseQueueName "perf_source")
dlq = checked (P.parseQueueName "perf_admin")

adminFor :: Pool.Pool -> DeadLetterAdmin
adminFor pool =
  checked $
    mkDeadLetterAdmin pool $
      (defaultDeadLetterAdminConfig [DlqRegistration dlq [source]]) {redriveEnabled = True}

db :: (Pool.Pool -> IO Value) -> IO Value
db action = withPgmqDb action >>= pure . checked

sql :: Pool.Pool -> T.Text -> IO ()
sql pool statement = runPgmqSession pool $ S.statement () (St.unpreparable statement E.noParams D.noResult)

-- Fixture envelopes have distinct IDs and original bodies distinguishable by
-- workers, so background redrives never count as original throughput.
seed :: Pool.Pool -> String -> Int -> Int -> IO ()
seed pool layout rows bytes = do
  runPgmqSession pool $ do
    Q.createQueue source
    (if layout == "unlogged" then Q.createUnloggedQueue else Q.createQueue) dlq
  sql pool $
    "insert into pgmq.q_perf_admin (vt, message, headers) select now(), jsonb_build_object('original_message', repeat('x', "
      <> T.pack (show (bytes - 2))
      <> "), 'original_queue', 'perf_source', 'dead_letter_reason_code', 'invalid_payload', 'dead_letter_reason_detail', 'invalid'), '{}'::jsonb from generate_series(1, "
      <> T.pack (show rows)
      <> ")"
  sql pool "analyze pgmq.q_perf_admin"

prepareAdmin :: String -> Int -> Pool.Pool -> IORef Bool -> IO (IO Value)
prepareAdmin mode seconds pool measuring
  | mode == "none" = pure (pure Null)
  | otherwise = do
      let admin = adminFor pool
      void $ evaluate admin
      if mode == "idle"
        then pure (pure (object ["mode" .= mode]))
        else do
          -- Workers have already seeded their source. Only this separate DLQ is
          -- initialized here; avoid recreating the source queue.
          runPgmqSession pool (Q.createQueue dlq)
          sql pool "insert into pgmq.q_perf_admin (vt, message, headers) select now(), jsonb_build_object('original_message', 'background', 'original_queue', 'perf_source', 'dead_letter_reason_code', 'invalid_payload', 'dead_letter_reason_detail', repeat('x', 1000), 'original_headers', jsonb_build_object('x-pgmq-group', (i % 100)::text)), '{}'::jsonb from generate_series(1, 100000) i"
          semaphore <- newQSem 2
          observations <- newIORef ([] :: [(Bool, Double, String)])
          started <- newIORef (0 :: Int)
          driver <- async $ do
            let awaitStart = readIORef measuring >>= \active -> unless active (threadDelay 1000 >> awaitStart)
            awaitStart
            origin <- getMonotonicTimeNSec
            calls <- forM [0 .. seconds * 11 - 1] $ \index -> do
              let slot = index `mod` 11
                  scheduled = origin + fromIntegral (index `div` 11) * 1000000000 + fromIntegral slot * 90909090
                  kind = if slot < 5 then "browse" else if slot < 10 then "fetch" else "redrive"
              now <- getMonotonicTimeNSec
              whenDelay scheduled now
              async $ bracket_ (waitQSem semaphore) (signalQSem semaphore) $ do
                atomicModifyIORef' started (\n -> (n + 1, ()))
                ok <- case kind of
                  "browse" ->
                    browseDeadLetters admin dlq (DlqPageRequest 50 (Just (DlqCursor dlq (P.MessageId 10000)))) >>= \r -> case r of
                      Right page -> consumePage page >> pure (V.length page.items == 50)
                      Left _ -> pure False
                  "fetch" ->
                    fetchDeadLetter admin dlq (P.MessageId 20000) >>= \r -> case r of
                      Right item -> consumeItem item >> pure True
                      Left _ -> pure False
                  _ ->
                    redriveDeadLetter admin dlq (P.MessageId (fromIntegral (1 + index `div` 11))) >>= \r -> pure $ case r of
                      Right (Redriven _) -> True
                      _ -> False
                end <- getMonotonicTimeNSec
                atomicModifyIORef' observations (\xs -> ((ok, fromIntegral (end - scheduled) / 1e6, kind) : xs, ()))
            pure calls
          pure $ do
            calls <- wait driver
            completed <- timeout 5000000 (mapM_ wait calls)
            case completed of
              Nothing -> error "administration backlog exceeded five-second drain"
              Just () -> pure ()
            rows <- readIORef observations
            startedCount <- readIORef started
            let success = length (filter (\(ok, _, _) -> ok) rows)
            pure $
              object
                [ "mode" .= mode,
                  "scheduled" .= (seconds * 11),
                  "started" .= startedCount,
                  "completed" .= length rows,
                  "successful" .= success,
                  "failed" .= (length rows - success),
                  "p95Ms" .= percentile 0.95 [latency | (_, latency, _) <- rows],
                  "redriveP50Ms" .= percentile 0.5 [latency | (_, latency, kind) <- rows, kind == "redrive"],
                  "redriveP95Ms" .= percentile 0.95 [latency | (_, latency, kind) <- rows, kind == "redrive"],
                  "redrivePerSecond" .= (fromIntegral (length [() | (True, _, "redrive") <- rows]) / fromIntegral seconds :: Double),
                  "observations" .= [object ["success" .= ok, "scheduledLatencyMs" .= latency, "kind" .= kind] | (ok, latency, kind) <- rows]
                ]

whenDelay :: (Integral a) => a -> a -> IO ()
whenDelay target now = if target > now then threadDelay (fromIntegral ((target - now) `div` 1000)) else pure ()

consumeRow :: P.Message -> IO ()
consumeRow msg = void $ evaluate $ force (P.unMessageBody msg.body, msg.headers)

consumeItem :: DeadLetterItem -> IO ()
consumeItem item = do
  consumeRow item.rawMessage
  case item.decodedEntry of
    Left err -> error (show err)
    Right entry -> void $ evaluate $ force (entry.originalPayload, entry.reasonDetail, entry.reasonCode, entry.originalHeaders)

consumePage :: DeadLetterPage -> IO ()
consumePage page = V.mapM_ consumeItem page.items

raw :: Pool.Pool -> Tx.Transaction a -> IO a
raw pool tx = runPgmqSession pool $ TS.transactionNoRetry TS.ReadCommitted TS.Read $ do
  void $
    Tx.statement () $
      St.unpreparable
        "select set_config('statement_timeout', '5000ms', true), set_config('lock_timeout', '1000ms', true)"
        E.noParams
        (D.singleRow ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))
  tx

readOperation :: Pool.Pool -> DeadLetterAdmin -> String -> Int -> Int -> Bool -> IO ()
readOperation pool admin mode cursor limit fetch
  | mode == "raw" = do
      rows <- raw pool $ do
        table <- Tx.statement ("perf_admin", "q") Inspection.formatTableName
        if fetch
          then maybe V.empty V.singleton <$> Tx.statement (P.MessageId (fromIntegral (cursor + 1))) (Inspection.lookupStatement table)
          else Tx.statement (Just (P.MessageId (fromIntegral cursor)), fromIntegral limit + 1) (Inspection.peekStatement table)
      V.mapM_ consumeRow rows
      unless (V.length rows == if fetch then 1 else limit + 1) $ error "raw fixture returned incomplete results"
  | fetch = fetchDeadLetter admin dlq (P.MessageId (fromIntegral (cursor + 1))) >>= consumeItem . checked
  | otherwise = do
      page <- browseDeadLetters admin dlq (DlqPageRequest (fromIntegral limit) (Just (DlqCursor dlq (P.MessageId (fromIntegral cursor))))) >>= pure . checked
      consumePage page
      unless (V.length page.items == limit) $ error "adapter fixture returned incomplete results"

-- Sample every position/limit in a round-robin loop during the same wall-clock
-- window. Each query retains its own observations; no percentiles are pooled.
readMatrix :: Pool.Pool -> String -> Int -> Int -> String -> Int -> Int -> IO Value
readMatrix pool layout depth bytes mode warm seconds = do
  seed pool layout depth bytes
  let admin = adminFor pool
      cases = [(position, cursor, limit, fetch) | (position, cursor) <- [("first" :: String, 0), ("middle", min (depth `div` 2) (depth - 502)), ("tail", depth - 502)], limit <- [50, 500], fetch <- [False, True]]
  warmEnd <- (+ fromIntegral warm * 1000000000) <$> getMonotonicTimeNSec
  let warmLoop = do
        forM_ cases $ \(_, cursor, limit, fetch) -> readOperation pool admin mode cursor limit fetch
        now <- getMonotonicTimeNSec
        if now < warmEnd then warmLoop else pure ()
  warmLoop
  refs <- replicateM (length cases) (newIORef [])
  deadline <- (+ fromIntegral seconds * 1000000000) <$> getMonotonicTimeNSec
  let loop = do
        forM_ (zip cases refs) $ \((_, cursor, limit, fetch), ref) -> do
          start <- getMonotonicTimeNSec
          readOperation pool admin mode cursor limit fetch
          end <- getMonotonicTimeNSec
          modifyIORef' ref (fromIntegral (end - start) / 1e6 :)
        now <- getMonotonicTimeNSec
        if now < deadline then loop else pure ()
  loop
  measurements <- forM (zip cases refs) $ \((position, cursor, limit, fetch), ref) -> do
    observations <- readIORef ref
    plans <- explain pool cursor limit fetch
    pure $
      object
        [ "position" .= position,
          "limit" .= limit,
          "fetch" .= fetch,
          "p95Ms" .= percentile 0.95 observations,
          "observationsMs" .= observations,
          "explain" .= plans,
          "count" .= length observations
        ]
  storage <- runPgmqSession pool $ S.statement () $ St.unpreparable "select pg_column_size(message)::int8 from pgmq.q_perf_admin where msg_id = 1" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))
  pure $ object ["layout" .= layout, "depth" .= depth, "bodyBytes" .= bytes, "mode" .= mode, "cases" .= measurements, "jsonbColumnBytes" .= storage]

explain :: Pool.Pool -> Int -> Int -> Bool -> IO Value
explain pool cursor limit fetch =
  runPgmqSession pool $
    S.statement () $
      St.unpreparable
        ( "explain (analyze, buffers, format json) select msg_id, read_ct, enqueued_at, last_read_at, vt, message, headers from pgmq.q_perf_admin where msg_id "
            <> (if fetch then "= " <> T.pack (show (cursor + 1)) else "> " <> T.pack (show cursor) <> " order by msg_id limit " <> T.pack (show (limit + 1)))
        )
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.json)))

retention :: Pool.Pool -> Int -> IO Value
retention pool seconds = do
  seed pool "ordinary" 1000 100000
  let admin = adminFor pool
  origin <- getMonotonicTimeNSec
  samples <- newIORef ([] :: [(Double, Integer)])
  allocations <- newIORef ([] :: [Integer])
  count <- newIORef (0 :: Int)
  let loop = do
        performMajorGC
        before <- getRTSStats
        replicateM 10 (readOperation pool admin "adapter" 0 500 False) >> pure ()
        performMajorGC
        after <- getRTSStats
        now <- getMonotonicTimeNSec
        let elapsed = fromIntegral (now - origin) / 1e9 :: Double
        modifyIORef' samples ((elapsed, fromIntegral (gcdetails_live_bytes (gc after))) :)
        modifyIORef' allocations (fromIntegral (allocated_bytes after - allocated_bytes before) `div` 10 :)
        modifyIORef' count (+ 10)
        if elapsed < fromIntegral seconds then loop else pure ()
  loop
  rows <- reverse <$> readIORef samples
  allocs <- readIORef allocations
  pages <- readIORef count
  stats <- getRTSStats
  pure $
    object
      [ "heapSamples" .= [object ["seconds" .= t, "liveBytes" .= b] | (t, b) <- rows],
        "pages" .= pages,
        "allocationsPerPage" .= allocs,
        "peakResidency" .= max_live_bytes stats
      ]

percentile :: Double -> [Double] -> Double
percentile _ [] = 0
percentile p values = let xs = sort values in xs !! min (length xs - 1) (ceiling (p * fromIntegral (length xs)) - 1)

-- NOINLINE prevents the optimizer from sharing encodings across iterations;
-- varying message IDs also exercise metadata without allocating body copies.
{-# NOINLINE encodeOne #-}
encodeOne :: Bool -> Bool -> DeadLetterReason -> P.Message -> Int -> IO Integer
encodeOne aware metadata reason msg nonce =
  evaluate $
    fromIntegral $
      LBS.length $
        encode $
          P.unMessageBody $
            (if aware then mkDlqPayloadForQueue source else mkDlqPayload) (msg {P.messageId = P.MessageId (fromIntegral nonce)}) reason metadata

encodingMatrix :: String -> Int -> Int -> IO Value
encodingMatrix mode warm seconds = do
  let code = checked (mkDeadLetterCode "orders.validation.failed")
      reasons = [("poison", PoisonPill "corrupt"), ("invalid", InvalidPayload "invalid"), ("retries", MaxRetriesExceeded), ("application", ApplicationFailure code "注文: exact reason"), ("detail8k", ApplicationFailure code (T.replicate 8192 "x"))]
      cases = [(label, bytes, metadata, reason) | (label, reason) <- reasons, bytes <- [100, 10000, 100000], metadata <- [False, True]]
      aware = mode == "aware"
      base bytes = P.Message {P.messageId = P.MessageId 42, P.readCount = 5, P.enqueuedAt = UTCTime (fromGregorian 2026 8 10) 0, P.lastReadAt = Just (UTCTime (fromGregorian 2026 8 10) 0), P.visibilityTime = UTCTime (fromGregorian 2026 8 10) 0, P.body = P.MessageBody (String (T.replicate (bytes - 2) "x")), P.headers = Nothing}
  -- Distribute >=60 seconds across short encoding cases, each batching enough
  -- operations for both timer resolution and allocation statistics.
  results <- forM cases $ \(label, bytes, metadata, reason) -> do
    let msg = base bytes
    original <- encodeOne False metadata reason msg 42
    queueAware <- encodeOne True metadata reason msg 42
    let delta = queueAware - original
        expected = fromIntegral (LBS.length (encode (object ["original_queue" .= P.queueNameToText source])) - 1)
    unless (delta == expected) $ error "source field byte growth mismatch"
    let runFor duration record = do
          deadline <- (+ floor (duration * 1e9 :: Double)) <$> getMonotonicTimeNSec
          let batch nonce total = do
                forM_ [nonce .. nonce + 99] $ \i -> void $ encodeOne aware metadata reason msg i
                now <- getMonotonicTimeNSec
                if now < deadline then batch (nonce + 100) (total + 100) else pure (total + 100 :: Int)
          if record then batch 1 0 else batch 1 0
    void $ runFor (fromIntegral warm / fromIntegral (length cases)) False
    performMajorGC
    before <- getRTSStats
    start <- getMonotonicTimeNSec
    n <- runFor (fromIntegral seconds / fromIntegral (length cases)) True
    end <- getMonotonicTimeNSec
    performMajorGC
    after <- getRTSStats
    pure $
      object
        [ "reason" .= (label :: String),
          "bodyBytes" .= bytes,
          "metadata" .= metadata,
          "operations" .= n,
          "nsPerOp" .= (fromIntegral (end - start) / fromIntegral n :: Double),
          "allocatedPerOp" .= (fromIntegral (allocated_bytes after - allocated_bytes before) / fromIntegral n :: Double),
          "sourceFieldBytes" .= delta
        ]
  pure $ object ["mode" .= mode, "cases" .= results]
