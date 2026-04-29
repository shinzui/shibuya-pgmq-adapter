-- | Message simulator for the PGMQ example.
--
-- Produces realistic test messages to various queues with OpenTelemetry
-- distributed tracing. Each message includes W3C Trace Context headers
-- that link producer spans to consumer spans.
--
-- Usage:
--
-- @
-- export DATABASE_URL="postgres://user:pass@localhost/pgmq"
-- export OTEL_TRACING_ENABLED=true
-- cabal run shibuya-pgmq-simulator -- --queue orders --count 100
-- cabal run shibuya-pgmq-simulator -- --queue payments --count 50 --rate 10
-- cabal run shibuya-pgmq-simulator -- --queue notifications --count 1000 --batch 50
-- @
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, replicateM, when)
import Data.Aeson (Value, decode, encode, object, (.=))
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Effectful qualified
import Effectful.Error.Static (runErrorNoCallStack)
import Example.Config
  ( QueueTarget (..),
    parseQueueTarget,
  )
import Example.Database
  ( backoffDemoQueueName,
    createQueues,
    notificationsQueueName,
    ordersQueueName,
    paymentsQueueName,
    withDatabasePool,
  )
import Example.Telemetry (withTracing)
import Hasql.Pool qualified as Pool
import OpenTelemetry.Trace qualified as OTel
import OpenTelemetry.Trace.Core qualified as OTelCore
import Pgmq.Effectful
  ( PgmqRuntimeError,
    SendMessage (..),
    runPgmq,
    runPgmqTraced,
    sendMessage,
  )
import Pgmq.Effectful.Traced (sendMessageTraced)
import Pgmq.Types
  ( MessageBody (..),
    MessageId (..),
    QueueName,
    parseQueueName,
  )
import System.Environment (getArgs, getEnv, lookupEnv)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import System.Random (randomRIO)

--------------------------------------------------------------------------------
-- CLI Parsing
--------------------------------------------------------------------------------

data CliArgs = CliArgs
  { queue :: !QueueTarget,
    count :: !Int,
    rate :: !Int,
    batchSize :: !Int
  }

parseArgs :: IO CliArgs
parseArgs = do
  args <- getArgs
  let parsed = parseArgPairs args
  queue <- case lookup "--queue" parsed of
    Just q -> case parseQueueTarget q of
      Just t -> pure t
      Nothing -> fail $ "Invalid queue: " <> q <> ". Use: orders, payments, notifications"
    Nothing -> pure OrdersQueue

  count <- getArgInt parsed "--count" 100
  rate <- getArgInt parsed "--rate" 50
  batch <- getArgInt parsed "--batch-size" 10

  pure
    CliArgs
      { queue = queue,
        count = count,
        rate = rate,
        batchSize = batch
      }

parseArgPairs :: [String] -> [(String, String)]
parseArgPairs [] = []
parseArgPairs [_] = []
parseArgPairs (k : v : rest) = (k, v) : parseArgPairs rest

getArgInt :: [(String, String)] -> String -> Int -> IO Int
getArgInt pairs key def = pure $ maybe def read (lookup key pairs)

--------------------------------------------------------------------------------
-- Message Generation
--------------------------------------------------------------------------------

-- | Generate a random order message.
generateOrder :: Int -> IO LBS.ByteString
generateOrder idx = do
  numItems <- randomRIO (1, 5 :: Int)
  items <- replicateM numItems generateOrderItem
  let totalAmount = sum [fromIntegral q * p | (_, _, q, p) <- items]
  pure $
    encode $
      object
        [ "orderId" .= ("ORD-" <> show idx),
          "customerId" .= ("CUST-" <> show (idx `mod` 100)),
          "items" .= [mkItem i | i <- items],
          "totalAmount" .= totalAmount,
          "status" .= ("Pending" :: Text)
        ]
  where
    mkItem (prodId, name, qty, price) =
      object
        [ "productId" .= prodId,
          "productName" .= name,
          "quantity" .= qty,
          "unitPrice" .= price
        ]

    generateOrderItem :: IO (Text, Text, Int, Double)
    generateOrderItem = do
      prodIdx <- randomRIO (1, 1000 :: Int)
      qty <- randomRIO (1, 5)
      price <- randomRIO (9.99, 199.99 :: Double)
      pure
        ( "PROD-" <> Text.pack (show prodIdx),
          "Product " <> Text.pack (show prodIdx),
          qty,
          price
        )

-- | Generate a random payment message.
-- Returns (message, customerId for FIFO grouping)
generatePayment :: Int -> IO (LBS.ByteString, Text)
generatePayment idx = do
  customerId <- pure $ "CUST-" <> Text.pack (show (idx `mod` 50))
  amount <- randomRIO (10.0, 5000.0 :: Double)
  methodIdx <- randomRIO (0, 3 :: Int)
  let methods = ["CreditCard", "DebitCard", "BankTransfer", "Wallet"] :: [Text]
      method = methods !! methodIdx
  pure
    ( encode $
        object
          [ "paymentId" .= ("PAY-" <> show idx),
            "orderId" .= ("ORD-" <> show idx),
            "customerId" .= customerId,
            "amount" .= amount,
            "currency" .= ("USD" :: Text),
            "method" .= method,
            "status" .= ("PaymentPending" :: Text)
          ],
      customerId
    )

-- | Generate a random notification message.
generateNotification :: Int -> IO LBS.ByteString
generateNotification idx = do
  typeIdx <- randomRIO (0, 2 :: Int)
  priorityIdx <- randomRIO (0, 3 :: Int)
  let types = ["Email", "SMS", "Push"] :: [Text]
      priorities = ["Low", "Normal", "High", "Urgent"] :: [Text]
  pure $
    encode $
      object
        [ "notificationId" .= ("NOTIF-" <> show idx),
          "userId" .= ("USER-" <> show (idx `mod` 1000)),
          "notificationType" .= (types !! typeIdx),
          "title" .= ("Notification " <> show idx),
          "body" .= ("This is notification message #" <> show idx),
          "priority" .= (priorities !! priorityIdx)
        ]

--------------------------------------------------------------------------------
-- Sending Logic
--------------------------------------------------------------------------------

sendToQueue ::
  Pool.Pool ->
  OTel.Tracer ->
  QueueTarget ->
  Int ->
  Int ->
  Int ->
  IO ()
sendToQueue pool tracer target count rate batchSize = do
  let queueName = targetToQueueName target
      delayMicros = if rate > 0 then 1_000_000 `div` rate else 0

  Text.putStrLn $ "Sending " <> Text.pack (show count) <> " messages to " <> Text.pack (show target)
  Text.putStrLn $ "  Rate: " <> Text.pack (show rate) <> " msg/s"
  Text.putStrLn $ "  Batch size: " <> Text.pack (show batchSize)
  Text.putStrLn ""

  case target of
    OrdersQueue -> sendBatchedTraced pool tracer queueName count batchSize delayMicros generateOrder
    PaymentsQueue -> sendPaymentsFifoTraced pool tracer queueName count delayMicros
    NotificationsQueue -> sendBatchedTraced pool tracer queueName count batchSize delayMicros generateNotification

targetToQueueName :: QueueTarget -> QueueName
targetToQueueName OrdersQueue = ordersQueueName
targetToQueueName PaymentsQueue = paymentsQueueName
targetToQueueName NotificationsQueue = notificationsQueueName

-- | Send messages with tracing, using batched progress reporting.
-- Each message is sent individually with its own producer span.
sendBatchedTraced ::
  Pool.Pool ->
  OTel.Tracer ->
  QueueName ->
  Int ->
  Int ->
  Int ->
  (Int -> IO LBS.ByteString) ->
  IO ()
sendBatchedTraced pool tracer queueName count batchSize delayMicros generator = do
  let batches = [1, 1 + batchSize .. count]
  forM_ (zip [1 ..] batches) $ \(batchNum :: Int, startIdx) -> do
    let endIdx = min (startIdx + batchSize - 1) count
        indices = [startIdx .. endIdx]

    -- Send each message with tracing
    forM_ indices $ \idx -> do
      body <- generator idx
      let payload = MessageBody (decodePayload body)
      -- Create producer span and send with trace context
      OTel.inSpan tracer "pgmq.produce" producerSpanArgs $ do
        result :: Either PgmqRuntimeError () <- Effectful.runEff $ runErrorNoCallStack $ runPgmqTraced pool tracer $ do
          _ <- sendMessageTraced (OTelCore.getTracerTracerProvider tracer) queueName payload Nothing
          pure ()
        case result of
          Left err -> Text.putStrLn $ "Error sending message: " <> Text.pack (show err)
          Right () -> pure ()

    when (batchNum `mod` 10 == 0) $
      Text.putStrLn $
        "  Sent batch " <> Text.pack (show batchNum) <> " (" <> Text.pack (show endIdx) <> "/" <> Text.pack (show count) <> ")"

    when (delayMicros > 0) $ threadDelay delayMicros

  Text.putStrLn $ "Done! Sent " <> Text.pack (show count) <> " messages."

-- | Send payment messages with FIFO grouping and tracing.
-- Each payment gets its own producer span with trace context injected.
sendPaymentsFifoTraced ::
  Pool.Pool ->
  OTel.Tracer ->
  QueueName ->
  Int ->
  Int ->
  IO ()
sendPaymentsFifoTraced pool tracer queueName count delayMicros = do
  forM_ [1 .. count] $ \idx -> do
    (body, customerId) <- generatePayment idx
    let payload = MessageBody (decodePayload body)
        -- FIFO headers will be merged with trace headers
        fifoHeaders = Just $ object ["x-pgmq-group" .= customerId]

    -- Create producer span and send with trace context + FIFO headers
    OTel.inSpan tracer "pgmq.produce" producerSpanArgs $ do
      result :: Either PgmqRuntimeError () <- Effectful.runEff $ runErrorNoCallStack $ runPgmqTraced pool tracer $ do
        _ <- sendMessageTraced (OTelCore.getTracerTracerProvider tracer) queueName payload fifoHeaders
        pure ()
      case result of
        Left err -> Text.putStrLn $ "Error sending payment: " <> Text.pack (show err)
        Right () -> pure ()

    when (idx `mod` 50 == 0) $
      Text.putStrLn $
        "  Sent " <> Text.pack (show idx) <> "/" <> Text.pack (show count) <> " payments"

    when (delayMicros > 0) $ threadDelay delayMicros

  Text.putStrLn $ "Done! Sent " <> Text.pack (show count) <> " payments with FIFO grouping."

-- | Span arguments for producer spans
producerSpanArgs :: OTel.SpanArguments
producerSpanArgs = OTel.defaultSpanArguments {OTel.kind = OTel.Producer}

-- | Decode lazy bytestring to Aeson Value.
decodePayload :: LBS.ByteString -> Value
decodePayload bs = case decode bs of
  Just v -> v
  Nothing -> error "Failed to decode payload"

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  rawArgs <- getArgs
  case rawArgs of
    ("one-shot" : rest) -> runOneShotMain rest
    _ -> runDefaultMain

runDefaultMain :: IO ()
runDefaultMain = do
  Text.putStrLn "=== Shibuya PGMQ Simulator ==="
  Text.putStrLn ""

  args <- parseArgs
  connStr <- fmap BS.pack $ getEnv "DATABASE_URL"

  -- Check if tracing is enabled
  tracingEnabled <- isTracingEnabled
  let serviceName = "shibuya-pgmq-simulator"

  when tracingEnabled $
    Text.putStrLn "OpenTelemetry tracing: ENABLED"

  now <- getCurrentTime
  Text.putStrLn $ "Started at: " <> Text.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" now)
  Text.putStrLn ""

  withDatabasePool connStr $ \pool -> do
    Text.putStrLn "Creating queues if needed..."
    createQueues pool
    Text.putStrLn ""

    -- Run with tracing (real or no-op depending on config)
    withTracing tracingEnabled serviceName $ \tracer -> do
      sendToQueue pool tracer args.queue args.count args.rate args.batchSize

  Text.putStrLn ""
  Text.putStrLn "Simulator finished."

-- | Enqueue a single message and exit. The companion to the consumer's
-- @backoff-demo@ subcommand: by default it targets the @backoff_demo@
-- queue, but the caller can pass any pgmq-valid queue name as the
-- second argument (e.g. @one-shot orders@).
--
-- The message body is a tiny JSON object with the timestamp at which
-- the simulator enqueued it; the consumer's stdout transcript can then
-- be visually compared against this anchor.
runOneShotMain :: [String] -> IO ()
runOneShotMain args = do
  Text.putStrLn "=== Shibuya PGMQ One-Shot Simulator ==="
  Text.putStrLn ""

  qName <- case args of
    (qStr : _) -> case parseQueueName (Text.pack qStr) of
      Right q -> pure q
      Left err -> error $ "Invalid queue name " <> show qStr <> ": " <> show err
    [] -> pure backoffDemoQueueName

  Text.putStrLn $ "Target queue: " <> Text.pack (show qName)

  connStr <- fmap BS.pack $ getEnv "DATABASE_URL"
  now <- getCurrentTime

  withDatabasePool connStr $ \pool -> do
    Text.putStrLn "Creating queues if needed..."
    createQueues pool

    let payload =
          MessageBody $
            object
              [ "demo" .= ("backoff" :: Text),
                "enqueuedAt" .= Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" now)
              ]
        sendArgs =
          SendMessage
            { queueName = qName,
              messageBody = payload,
              delay = Nothing
            }

    result :: Either PgmqRuntimeError MessageId <- Effectful.runEff $ runErrorNoCallStack $ runPgmq pool $ sendMessage sendArgs
    case result of
      Left err -> Text.putStrLn $ "Error sending message: " <> Text.pack (show err)
      Right (MessageId mid) ->
        Text.putStrLn $ "Sent message id=" <> Text.pack (show mid) <> " to queue " <> Text.pack (show qName)

  Text.putStrLn ""
  Text.putStrLn "One-shot simulator finished."

-- | Check if OpenTelemetry tracing is enabled via environment variable.
isTracingEnabled :: IO Bool
isTracingEnabled = do
  val <- lookupEnv "OTEL_TRACING_ENABLED"
  pure $ case val of
    Just "true" -> True
    Just "1" -> True
    Just "yes" -> True
    _ -> False
