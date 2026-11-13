-- | Trace correlation of PGMQ processing spans against a real PostgreSQL.
--
-- Each case sends a message carrying a known producer @traceparent@, runs a
-- traced Shibuya app over the adapter with an in-memory span exporter, and
-- inspects the exported Consumer spans: their trace, their parent and their
-- links. The dead-letter cases also read the dead-letter queue message's
-- headers, which 'Shibuya.Adapter.Pgmq.Internal.mergeDlqHeaders' writes from
-- the active processing span.
--
-- Run with: cabal test shibuya-pgmq-adapter-test --test-option=--match --test-option=Correlation
module Shibuya.Adapter.Pgmq.CorrelationSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception qualified as Exception
import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import OpenTelemetry.Attributes (emptyAttributes)
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id (Base (..))
import OpenTelemetry.Trace.Id qualified as OTel.Id
import OpenTelemetry.Trace.Id.Generator (IdGenerator (..))
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq)
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types (ReadMessage (..), SendMessageWithHeaders (..))
import Pgmq.Types (Message (..), MessageBody (..), MessageHeaders (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq
  ( AdapterTelemetry (traceCorrelation),
    PgmqAdapterConfig (..),
    PollingConfig (..),
    TraceCorrelation (..),
    defaultAdapterTelemetry,
    defaultConfig,
    directDeadLetter,
    mkPgmqAdapterEnv,
    pgmqAdapter,
  )
import Shibuya.App (ProcessorId (..), ShutdownConfig (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..))
import Shibuya.Handler (Handler)
import Shibuya.Telemetry.Effect (Tracing, runTracing)
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic (processSpanName)
import System.Environment (lookupEnv)
import Test.Hspec
import TmpPostgres (TestFixture (..), runPgmqSession, withPgmqDb, withTestFixture)

spec :: Spec
spec = around withTempDbFixture $ describe "Correlation" $ do
  it "ParentAndLink: process span is a child of the producer with one link" $ \fixture -> do
    run <- runCorrelated fixture defaultAdapterTelemetry False (countingHandler AckOk) 1
    run.adapterPolicy `shouldBe` ParentAndLink
    [sp] <- pure run.spans
    sp.name `shouldBe` processSpanName processorName
    hexTrace sp.context `shouldBe` producerTraceHex
    fmap hexSpan sp.parent `shouldBe` Just producerSpanHex
    linkIds sp `shouldBe` [(producerTraceHex, producerSpanHex)]

  it "LinkOnly: process span is a linked root" $ \fixture -> do
    run <- runCorrelated fixture linkOnly False (countingHandler AckOk) 1
    run.adapterPolicy `shouldBe` LinkOnly
    [sp] <- pure run.spans
    hexTrace sp.context `shouldNotBe` producerTraceHex
    isNothing sp.parent `shouldBe` True
    linkIds sp `shouldBe` [(producerTraceHex, producerSpanHex)]

  it "ParentAndLink: every redelivery stays in the producer's trace" $ \fixture -> do
    run <- runCorrelated fixture defaultAdapterTelemetry False retryOnceHandler 2
    length run.spans `shouldBe` 2
    map (hexTrace . (.context)) run.spans `shouldBe` [producerTraceHex, producerTraceHex]
    map (fmap hexSpan . (.parent)) run.spans `shouldBe` [Just producerSpanHex, Just producerSpanHex]
    map linkIds run.spans `shouldBe` replicate 2 [(producerTraceHex, producerSpanHex)]

  it "LinkOnly: each redelivery is its own linked trace" $ \fixture -> do
    run <- runCorrelated fixture linkOnly False retryOnceHandler 2
    case run.spans of
      [first, second] -> do
        hexTrace first.context `shouldNotBe` hexTrace second.context
        mapM_ (\sp -> hexTrace sp.context `shouldNotBe` producerTraceHex) [first, second]
        mapM_ (\sp -> isNothing sp.parent `shouldBe` True) [first, second]
        mapM_ (\sp -> linkIds sp `shouldBe` [(producerTraceHex, producerSpanHex)]) [first, second]
      other -> expectationFailure ("expected two processing spans, got " <> show (length other))

  it "LinkOnly: DLQ traceparent is the consumer's, upstream preserved" $ \fixture -> do
    run <- runCorrelated fixture linkOnly True (countingHandler (AckDeadLetter (PoisonPill "correlation"))) 1
    [sp] <- pure run.spans
    isNothing sp.parent `shouldBe` True
    linkIds sp `shouldBe` [(producerTraceHex, producerSpanHex)]
    hdrs <- readDlqHeaders fixture
    let stringHeader :: Text -> Maybe Text
        stringHeader k = case KeyMap.lookup (Key.fromText k) hdrs of
          Just (String v) -> Just v
          _ -> Nothing
        active = [(Text.encodeUtf8 k, Text.encodeUtf8 v) | k <- ["traceparent", "tracestate"], Just v <- [stringHeader k]]
    case extractTraceContext active of
      Nothing -> expectationFailure ("expected a decodable consumer traceparent in the DLQ, got " <> show hdrs)
      Just ctx -> do
        hexTrace ctx `shouldBe` hexTrace sp.context
        hexSpan ctx `shouldBe` hexSpan sp.context
        hexTrace ctx `shouldNotBe` producerTraceHex
        hexSpan ctx `shouldNotBe` producerSpanHex
    stringHeader "x-shibuya-upstream-traceparent" `shouldBe` Just producerParent
    stringHeader "x-shibuya-upstream-tracestate" `shouldBe` Just producerState

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

producerParent :: Text
producerParent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

producerState :: Text
producerState = "vendor=opaque"

producerTraceHex :: Text
producerTraceHex = "0af7651916cd43dd8448eb211c80319c"

producerSpanHex :: Text
producerSpanHex = "b7ad6b7169203331"

processorName :: Text
processorName = "pgmq-correlation"

linkOnly :: AdapterTelemetry
linkOnly = defaultAdapterTelemetry {traceCorrelation = LinkOnly}

data CorrelatedRun = CorrelatedRun
  { adapterPolicy :: TraceCorrelation,
    spans :: [ConsumerSpan]
  }

-- | Send one message with the producer headers, process it with the given
-- telemetry until the handler has been called @deliveries@ times, and return
-- the exported Consumer spans in the order they ended.
runCorrelated ::
  TestFixture ->
  AdapterTelemetry ->
  Bool ->
  (IORef Int -> Handler '[Tracing, Pgmq, Error PgmqRuntimeError, IOE] Value) ->
  Int ->
  IO CorrelatedRun
runCorrelated TestFixture {pool, queueName, dlqName} telemetry withDlq handler deliveries = do
  runPgmqSession pool $
    void $
      Sessions.sendMessageWithHeaders $
        SendMessageWithHeaders
          { queueName = queueName,
            messageBody = MessageBody (String "correlated"),
            messageHeaders = MessageHeaders (object ["traceparent" .= producerParent, "tracestate" .= producerState]),
            delay = Just 0
          }
  let config =
        (defaultConfig queueName)
          { visibilityTimeout = 5,
            batchSize = 1,
            polling = StandardPolling {pollInterval = 0.05},
            deadLetterConfig = if withDlq then Just (directDeadLetter dlqName True) else Nothing,
            telemetry = telemetry
          }
  calls <- newIORef (0 :: Int)
  (spanProcessor, spansRef) <- inMemoryListExporter
  policy <-
    Exception.bracket
      (OTel.createTracerProvider [spanProcessor] OTel.emptyTracerProviderOptions {OTel.tracerProviderOptionsIdGenerator = DefaultIdGenerator})
      (\p -> OTel.shutdownTracerProvider p (Just 5_000_000))
      $ \provider -> do
        let tracer = OTel.makeTracer provider (OTel.InstrumentationLibrary "pgmq-correlation" "" "" emptyAttributes) OTel.tracerOptions
        runAdapterIO pool $ runTracing tracer $ do
          adapter <- requireAdapter pool config
          result <- runApp defaultAppConfig [(ProcessorId processorName, mkProcessor adapter (handler calls))]
          case result of
            Left err -> liftIO (expectationFailure (show err))
            Right appHandle -> do
              liftIO $ waitForCalls calls deliveries 5_000_000
              drained <- stopAppGracefully defaultShutdownConfig {drainTimeout = 5} appHandle
              liftIO $ drained `shouldBe` True
          pure adapter.telemetry.traceCorrelation
  readIORef calls `shouldReturn` deliveries
  exported <- readIORef spansRef
  consumers <- consumerSpans exported
  pure CorrelatedRun {adapterPolicy = policy, spans = consumers}

countingHandler :: (IOE :> es) => AckDecision -> IORef Int -> Handler es Value
countingHandler decision calls _ = do
  liftIO $ atomicModifyIORef' calls (\n -> (n + 1, ()))
  pure decision

-- | Ask for an immediate redelivery on the first attempt, succeed afterwards.
retryOnceHandler :: (IOE :> es) => IORef Int -> Handler es Value
retryOnceHandler calls message = do
  liftIO $ atomicModifyIORef' calls (\n -> (n + 1, ()))
  pure $ case message.envelope.attempt of
    Just (Attempt n) | n > 0 -> AckOk
    _ -> AckRetry (RetryDelay 0)

readDlqHeaders :: TestFixture -> IO (KeyMap.KeyMap Value)
readDlqHeaders TestFixture {pool, dlqName} = do
  messages <- runPgmqSession pool $ Sessions.readMessage $ ReadMessage dlqName 30 (Just 10) Nothing
  case Vector.toList messages of
    [msg] -> case msg.headers of
      Just (Object hdrs) -> pure hdrs
      other -> expectationFailure ("expected DLQ headers, got " <> show other) >> pure KeyMap.empty
    other -> expectationFailure ("expected one DLQ message, got " <> show (length other)) >> pure KeyMap.empty

waitForCalls :: IORef Int -> Int -> Int -> IO ()
waitForCalls ref target = go
  where
    go remaining
      | remaining <= 0 = pure ()
      | otherwise = do
          n <- readIORef ref
          if n >= target then pure () else threadDelay 20_000 >> go (remaining - 20_000)

withTempDbFixture :: (TestFixture -> IO ()) -> IO ()
withTempDbFixture action = do
  skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"
  case skipDb of
    Just "1" -> pendingWith "Database tests skipped (PGMQ_TEST_SKIP_DB=1)"
    _ -> do
      result <- withPgmqDb $ \pool -> withTestFixture pool action
      case result of
        Left err -> expectationFailure $ "Failed to start temp database: " <> show err
        Right () -> pure ()

runAdapterIO :: Pool.Pool -> Eff '[Pgmq, Error PgmqRuntimeError, IOE] a -> IO a
runAdapterIO pool action = do
  result <- runEff $ runErrorNoCallStack $ runPgmq pool action
  either (\err -> error ("Pgmq error: " <> show err)) pure result

requireAdapter ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  Pool.Pool ->
  PgmqAdapterConfig ->
  Eff es (Adapter es Value)
requireAdapter pool config =
  pgmqAdapter (mkPgmqAdapterEnv pool) config
    >>= either (\err -> liftIO (error ("Invalid PGMQ adapter config: " <> show err))) pure

--------------------------------------------------------------------------------
-- Span inspection
--------------------------------------------------------------------------------

data ConsumerSpan = ConsumerSpan
  { name :: Text,
    context :: OTel.SpanContext,
    parent :: Maybe OTel.SpanContext,
    links :: [OTel.SpanContext]
  }

consumerSpans :: [OTel.ImmutableSpan] -> IO [ConsumerSpan]
consumerSpans exported = traverse describeSpan [sp | sp <- exported, OTel.spanKind sp == OTel.Consumer]
  where
    describeSpan sp = do
      hot <- readIORef (OTel.spanHot sp)
      parent <- traverse OTel.getSpanContext (OTel.spanParent sp)
      pure
        ConsumerSpan
          { name = OTel.hotName hot,
            context = OTel.spanContext sp,
            parent,
            links = map OTel.frozenLinkContext (toList (appendOnlyBoundedCollectionValues (OTel.hotLinks hot)))
          }

linkIds :: ConsumerSpan -> [(Text, Text)]
linkIds sp = [(hexTrace l, hexSpan l) | l <- sp.links]

hexTrace :: OTel.SpanContext -> Text
hexTrace ctx = OTel.Id.traceIdBaseEncodedText Base16 ctx.traceId

hexSpan :: OTel.SpanContext -> Text
hexSpan ctx = OTel.Id.spanIdBaseEncodedText Base16 ctx.spanId
