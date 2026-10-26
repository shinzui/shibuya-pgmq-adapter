module Shibuya.Adapter.Pgmq.DeadLetterSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, concurrently, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Pgmq.Effectful (PgmqRuntimeError, runPgmq)
import Pgmq.Hasql.Sessions qualified as S
import Pgmq.Hasql.Statements.Inspection qualified as Inspection
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types qualified as P
import Shibuya.Adapter.Pgmq
import Shibuya.Adapter.Pgmq.DeadLetter
import Shibuya.App (ProcessorId (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), mkDeadLetterCode)
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)
import Test.Hspec hiding (before)
import TmpPostgres

spec :: Spec
spec = describe "Dead-letter administration" $ do
  around database $ do
    it "preserves an application's exact reason through a real handler, browse and fetch" $ \fixture -> do
      let pool = fixture.pool
          source = fixture.queueName
          dlq = fixture.dlqName
          payload = object ["order" .= (42 :: Int)]
          detail = "注文の検証: failed: exact text"
          code = either (error . show) id (mkDeadLetterCode "orders.validation.failed")
          config =
            (defaultConfig source)
              { batchSize = 1,
                polling = StandardPolling 0.01,
                deadLetterConfig = Just (directDeadLetter dlq True)
              }
      void $ runPgmqSession pool $ S.sendMessage (Q.SendMessage source (P.MessageBody payload) Nothing)
      outcome <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmq pool $ runTracingNoop $ do
        adapter <- pgmqAdapter (mkPgmqAdapterEnv pool) config >>= either (error . show) pure
        app <- runApp defaultAppConfig [(ProcessorId "dlq-roundtrip", mkProcessor adapter (\_ -> pure (AckDeadLetter (ApplicationFailure code detail))))] >>= either (error . show) pure
        liftIO $ awaitDlq pool dlq
        drained <- stopAppGracefully defaultShutdownConfig app
        liftIO $ drained `shouldBe` True
      either throwIO pure outcome
      admin <- requireAdmin fixture False
      page <- browseDeadLetters admin dlq defaultDlqPageRequest >>= right
      V.length page.items `shouldBe` 1
      let item = V.head page.items
      entry <- right item.decodedEntry
      entry.reasonCode `shouldBe` "orders.validation.failed"
      entry.reasonDetail `shouldBe` String detail
      entry.originalPayload `shouldBe` payload
      entry.resolvedSource `shouldBe` Just source
      entry.sourceResolution `shouldBe` PayloadSource
      entry.originalReadCount `shouldBe` Just 1
      entry.dlqReadCount `shouldBe` 0
      entry.dlqEnqueuedAt `shouldBe` item.rawMessage.enqueuedAt
      fetchDeadLetter admin dlq item.rawMessage.messageId `shouldReturn` Right item
      redriveDeadLetter admin dlq item.rawMessage.messageId `shouldReturn` Left RedriveDisabled

    it "pages by exclusive IDs across malformed and invisible rows without changing any row" $ \fixture -> do
      admin <- requireAdmin fixture False
      browseDeadLetters admin fixture.dlqName defaultDlqPageRequest `shouldReturn` Right (DeadLetterPage V.empty Nothing)
      firstId <- seed fixture (envelope (String "first"))
      corruptId <- seed fixture (String "not an envelope")
      lastId <- seed fixture (envelope Null)
      void $ runPgmqSession fixture.pool $ S.readMessage (Q.ReadMessage fixture.dlqName 300 (Just 2) Nothing)
      before <- snapshot fixture.pool fixture.dlqName
      firstPage <- browseDeadLetters admin fixture.dlqName (DlqPageRequest 2 Nothing) >>= right
      V.map (\item -> item.rawMessage.messageId) firstPage.items `shouldBe` V.fromList [firstId, corruptId]
      firstPage.nextCursor `shouldBe` Just (DlqCursor fixture.dlqName corruptId)
      (firstPage.items V.! 1).decodedEntry `shouldSatisfy` isLeft
      lastPage <- browseDeadLetters admin fixture.dlqName (DlqPageRequest 2 firstPage.nextCursor) >>= right
      V.map (\item -> item.rawMessage.messageId) lastPage.items `shouldBe` V.singleton lastId
      lastPage.nextCursor `shouldBe` Nothing
      nullEntry <- right (V.head lastPage.items).decodedEntry
      nullEntry.originalPayload `shouldBe` Null
      forM_ before $ \msg -> void $ fetchDeadLetter admin fixture.dlqName msg.messageId >>= right
      snapshot fixture.pool fixture.dlqName `shouldReturn` before
      void $ runPgmqSession fixture.pool $ S.deleteMessage (Q.MessageQuery fixture.dlqName firstId)
      browseDeadLetters admin fixture.dlqName (DlqPageRequest 2 firstPage.nextCursor) `shouldReturn` Right lastPage
      exact <- browseDeadLetters admin fixture.dlqName (DlqPageRequest 2 Nothing) >>= right
      V.length exact.items `shouldBe` 2
      exact.nextCursor `shouldBe` Nothing
      fetchDeadLetter admin fixture.dlqName firstId `shouldReturn` Left (EntryNotFound fixture.dlqName firstId)

    it "decodes structured-only, dual-written and legacy history while preserving arbitrary JSON detail" $ \fixture -> do
      admin <- requireAdmin fixture False
      let detail = object ["nested" .= [Null, object ["ok" .= True]]]
          structured = object ["original_message" .= Null, "dead_letter_reason_code" .= ("invalid_payload" :: Text), "dead_letter_reason_detail" .= detail]
          legacy = object ["original_message" .= String "old", "dead_letter_reason" .= ("poison_pill: 原因: retained" :: Text)]
          bare = object ["original_message" .= Null, "dead_letter_reason" .= ("max_retries_exceeded" :: Text)]
      ids <- mapM (seed fixture) [structured, putField "dead_letter_reason" (String "ignored: legacy") structured, legacy, bare]
      entries <- mapM (\messageId -> fetchDeadLetter admin fixture.dlqName messageId >>= right >>= right . (\item -> item.decodedEntry)) ids
      map (\entry -> entry.reasonCode) entries `shouldBe` ["invalid_payload", "invalid_payload", "poison_pill", "max_retries_exceeded"]
      map (\entry -> entry.reasonDetail) entries `shouldBe` [detail, detail, String "原因: retained", Null]
      map (\entry -> entry.reasonRepresentation) entries `shouldBe` [StructuredReason, StructuredReason, LegacyReason, LegacyReason]
      forM_ entries $ \entry -> do
        entry.originalReadCount `shouldBe` Nothing
        entry.originalMessageId `shouldBe` Nothing
        entry.originalEnqueuedAt `shouldBe` Nothing
        entry.dlqReadCount `shouldBe` 0
        entry.sourceResolution `shouldBe` ConfiguredFallback
        entry.resolvedSource `shouldBe` Just fixture.queueName

    it "keeps malformed optional metadata and partial structured reasons inspectable and refuses redrive" $ \fixture -> do
      admin <- requireAdmin fixture True
      let payload = envelope (String "valid body")
          corrupt =
            [ ("original_message", deleteField "original_message" payload),
              ("dead_letter_reason_code", deleteField "dead_letter_reason_code" payload),
              ("dead_letter_reason_detail", deleteField "dead_letter_reason_detail" payload),
              ("dead_letter_reason_code", putField "dead_letter_reason_code" Null payload),
              ("original_queue", putField "original_queue" (Number 42) payload),
              ("original_queue", putField "original_queue" (String "../bad") payload),
              ("read_count", putField "read_count" (String "2") payload),
              ("original_message_id", putField "original_message_id" Null payload),
              ("original_enqueued_at", putField "original_enqueued_at" (String "not-a-time") payload),
              ("last_read_at", putField "last_read_at" (Number 7) payload)
            ]
      forM_ corrupt $ \(field, body) -> do
        messageId <- seed fixture body
        item <- fetchDeadLetter admin fixture.dlqName messageId >>= right
        case item.decodedEntry of
          Right _ -> expectationFailure "corrupt envelope decoded successfully"
          Left err -> do
            err.field `shouldBe` field
            redriveDeadLetter admin fixture.dlqName messageId `shouldReturn` Left (MalformedEnvelope err)
      rows <- snapshot fixture.pool fixture.dlqName
      page <- browseDeadLetters admin fixture.dlqName defaultDlqPageRequest >>= right
      V.length page.items `shouldBe` length corrupt
      snapshot fixture.pool fixture.dlqName `shouldReturn` rows

    it "validates limits, queue-bound cursors and managed queue identity before querying" $ \fixture -> do
      admin <- requireAdmin fixture False
      forM_ [0, -1, 501, maxBound] $ \limit ->
        browseDeadLetters admin fixture.dlqName (DlqPageRequest limit Nothing) `shouldReturn` Left (InvalidPageRequest (InvalidPageLimit limit))
      browseDeadLetters admin fixture.dlqName (DlqPageRequest 50 (Just (DlqCursor fixture.queueName (P.MessageId 1))))
        `shouldReturn` Left (InvalidPageRequest (CursorQueueMismatch fixture.dlqName fixture.queueName))
      browseDeadLetters admin fixture.queueName defaultDlqPageRequest `shouldReturn` Left (UnknownManagedDlq fixture.queueName)
      fetchDeadLetter admin fixture.queueName (P.MessageId 1) `shouldReturn` Left (UnknownManagedDlq fixture.queueName)
      redriveDeadLetter admin fixture.queueName (P.MessageId 1) `shouldReturn` Left RedriveDisabled

    it "does not turn missing tables into an empty page or EntryNotFound" $ \fixture -> do
      admin <- requireAdmin fixture False
      void $ runPgmqSession fixture.pool $ S.dropQueue fixture.dlqName
      browseDeadLetters admin fixture.dlqName defaultDlqPageRequest >>= (`shouldSatisfy` isDatabaseError)
      fetchDeadLetter admin fixture.dlqName (P.MessageId 1) >>= (`shouldSatisfy` isDatabaseError)
      runPgmqSession fixture.pool $ S.createQueue fixture.dlqName

    it "requires valid direct mappings and positive deadlines at handle construction" $ \fixture -> do
      let queue = fixture.dlqName
          source = fixture.queueName
          registration = DlqRegistration queue [source]
          config = defaultDeadLetterAdminConfig [registration]
          rejects cfg expected = case mkDeadLetterAdmin fixture.pool cfg of
            Left err -> err `shouldBe` expected
            Right _ -> expectationFailure "invalid config accepted"
      rejects (config {registrations = [registration, registration]}) (DuplicateManagedQueue queue)
      rejects (config {registrations = [DlqRegistration queue []]}) (EmptySourceQueues queue)
      rejects (config {registrations = [DlqRegistration queue [source, source]]}) (DuplicateSourceQueues queue)
      rejects (config {registrations = [DlqRegistration queue [queue]]}) (SelfMapping queue)
      rejects (config {statementTimeoutMs = 0}) (InvalidStatementTimeout 0)
      rejects (config {lockTimeoutMs = -1}) (InvalidLockTimeout (-1))
      registrationFromAdapterConfig (defaultConfig source) `shouldBe` Left NoDirectDeadLetterTarget
      registrationFromAdapterConfig ((defaultConfig source) {deadLetterConfig = Just (directDeadLetter queue False)}) `shouldBe` Right registration
      let key = either (error . show) id (P.parseRoutingKey "fail.orders")
      registrationFromAdapterConfig ((defaultConfig source) {deadLetterConfig = Just (topicDeadLetter key True)}) `shouldBe` Left NoDirectDeadLetterTarget
      registrationFromAdapterConfig ((defaultConfig source) {deadLetterConfig = Just (directDeadLetter source True)}) `shouldBe` Left (SelfMapping source)

    it "resolves registered shared DLQs by payload and refuses ambiguous or disallowed sources" $ \fixture -> do
      let other = namedQueue "another_source"
          forbidden = namedQueue "unregistered_source"
      admin <-
        right $
          mkDeadLetterAdmin fixture.pool $
            (defaultDeadLetterAdminConfig [DlqRegistration fixture.dlqName [fixture.queueName, other]]) {redriveEnabled = True}
      explicit <- seed fixture (putField "original_queue" (String (P.queueNameToText other)) (envelope Null))
      ambiguous <- seed fixture (envelope Null)
      disallowed <- seed fixture (putField "original_queue" (String (P.queueNameToText forbidden)) (envelope Null))
      item <- fetchDeadLetter admin fixture.dlqName explicit >>= right
      entry <- right item.decodedEntry
      entry.resolvedSource `shouldBe` Just other
      entry.sourceResolution `shouldBe` PayloadSource
      rows <- snapshot fixture.pool fixture.dlqName
      redriveDeadLetter admin fixture.dlqName ambiguous `shouldReturn` Left UnresolvedSource
      redriveDeadLetter admin fixture.dlqName disallowed `shouldReturn` Left (DisallowedSource forbidden)
      snapshot fixture.pool fixture.dlqName `shouldReturn` rows

    it "redrives the original payload once and preserves saved group/trace headers" $ \fixture -> do
      admin <- requireAdmin fixture True
      let body = object ["order" .= (42 :: Int)]
          saved = object ["x-pgmq-group" .= ("customer-a" :: Text), "traceparent" .= ("original" :: Text)]
          wrapper = putField "original_headers" saved (envelope body)
      messageId <- seedWithHeaders fixture wrapper (object ["traceparent" .= ("dlq" :: Text)])
      before <- snapshot fixture.pool fixture.dlqName
      disabled <- requireAdmin fixture False
      redriveDeadLetter disabled fixture.dlqName messageId `shouldReturn` Left RedriveDisabled
      snapshot fixture.pool fixture.dlqName `shouldReturn` before
      result <- redriveDeadLetter admin fixture.dlqName messageId >>= right
      newId <- case result of
        Redriven value -> pure value
        AlreadyAbsent -> expectationFailure "fresh row absent" >> fail "absent"
      snapshot fixture.pool fixture.dlqName `shouldReturn` V.empty
      sourceRows <- snapshot fixture.pool fixture.queueName
      V.length sourceRows `shouldBe` 1
      let restored = V.head sourceRows
      restored.messageId `shouldBe` newId
      restored.body `shouldBe` P.MessageBody body
      restored.headers `shouldBe` Just saved
      restored.readCount `shouldBe` 0
      redriveDeadLetter admin fixture.dlqName messageId `shouldReturn` Right AlreadyAbsent
      -- Discarded confirmed response followed by a fresh retry, not network loss.
      redriveDeadLetter admin fixture.dlqName messageId `shouldReturn` Right AlreadyAbsent
      snapshot fixture.pool fixture.queueName `shouldReturn` sourceRows
      consumed <- runPgmqSession fixture.pool $ S.readMessage (Q.ReadMessage fixture.queueName 30 (Just 1) Nothing)
      V.map (\msg -> msg.body) consumed `shouldBe` V.singleton (P.MessageBody body)

    it "distinguishes missing original headers from explicit null and accepts null payload" $ \fixture -> do
      admin <- requireAdmin fixture True
      let trace = object ["traceparent" .= ("dlq-span" :: Text), "x-pgmq-group" .= ("g" :: Text)]
      explicitNull <- seedWithHeaders fixture (putField "original_headers" Null (envelope Null)) trace
      missing <- seedWithHeaders fixture (envelope (String "metadata-disabled")) trace
      forM_ [explicitNull, missing] $ \messageId -> void $ redriveDeadLetter admin fixture.dlqName messageId >>= right
      rows <- snapshot fixture.pool fixture.queueName
      V.map (\msg -> msg.body) rows `shouldBe` V.fromList [P.MessageBody Null, P.MessageBody (String "metadata-disabled")]
      V.map (\msg -> msg.headers) rows `shouldBe` V.fromList [Just Null, Just trace]

    it "restores arbitrary JSON-valued saved headers supported by PGMQ" $ \fixture -> do
      admin <- requireAdmin fixture True
      let headers = [String "scalar", Array (V.fromList [Null, Bool True]), Number 7, Bool False]
      forM_ headers $ \saved -> do
        messageId <- seed fixture (putField "original_headers" saved (envelope Null))
        redriveDeadLetter admin fixture.dlqName messageId >>= (`shouldSatisfy` isRedriven)
      rows <- snapshot fixture.pool fixture.queueName
      V.map (\msg -> msg.headers) rows `shouldBe` V.fromList (map Just headers)

    it "serializes independent concurrent redrives on one durable row claim" $ \fixture -> do
      admin <- requireAdmin fixture True
      messageId <- seed fixture (envelope (String "race"))
      results <- concurrently (redriveDeadLetter admin fixture.dlqName messageId) (redriveDeadLetter admin fixture.dlqName messageId)
      case results of
        (Right (Redriven _), Right AlreadyAbsent) -> pure ()
        (Right AlreadyAbsent, Right (Redriven _)) -> pure ()
        _ -> expectationFailure (show results)
      rows <- snapshot fixture.pool fixture.queueName
      V.length rows `shouldBe` 1
      snapshot fixture.pool fixture.dlqName `shouldReturn` V.empty

    it "rolls the deletion back on send failure and can retry after the source is recreated" $ \fixture -> do
      admin <- requireAdmin fixture True
      messageId <- seed fixture (envelope (String "rollback"))
      before <- snapshot fixture.pool fixture.dlqName
      void $ runPgmqSession fixture.pool $ S.dropQueue fixture.queueName
      redriveDeadLetter admin fixture.dlqName messageId >>= (`shouldSatisfy` isDatabaseError)
      snapshot fixture.pool fixture.dlqName `shouldReturn` before
      runPgmqSession fixture.pool $ S.createQueue fixture.queueName
      redriveDeadLetter admin fixture.dlqName messageId >>= (`shouldSatisfy` isRedriven)
      rows <- snapshot fixture.pool fixture.queueName
      V.map (\msg -> msg.body) rows `shouldBe` V.singleton (P.MessageBody (String "rollback"))

    it "treats topic fan-out copies as two separately redrivable entries" $ \fixture -> do
      let other = namedQueue "topic_dlq_copy"
          key = either (error . show) id (P.parseRoutingKey "fail.orders")
          pattern' = either (error . show) id (P.parseTopicPattern "fail.#")
      runPgmqSession fixture.pool $ do
        S.createQueue other
        S.bindTopic (Q.BindTopic pattern' fixture.dlqName)
        S.bindTopic (Q.BindTopic pattern' other)
      produceFailure
        fixture
        ( (defaultConfig fixture.queueName)
            { batchSize = 1,
              polling = StandardPolling 0.01,
              deadLetterConfig = Just (topicDeadLetter key True)
            }
        )
        (String "fanout")
      admin <-
        right $
          mkDeadLetterAdmin fixture.pool $
            (defaultDeadLetterAdminConfig [DlqRegistration q [fixture.queueName] | q <- [fixture.dlqName, other]]) {redriveEnabled = True}
      copies <-
        mapM
          ( \q -> do
              page <- browseDeadLetters admin q defaultDlqPageRequest >>= right
              V.length page.items `shouldBe` 1
              pure (q, (V.head page.items).rawMessage.messageId)
          )
          [fixture.dlqName, other]
      ((q1, id1), (q2, id2)) <- case copies of
        [first, second] -> pure (first, second)
        _ -> expectationFailure "expected exactly two topic copies" >> fail "copy count"
      (r1, r2) <- concurrently (redriveDeadLetter admin q1 id1) (redriveDeadLetter admin q2 id2)
      r1 `shouldSatisfy` isRedriven
      r2 `shouldSatisfy` isRedriven
      rows <- snapshot fixture.pool fixture.queueName
      V.map (\msg -> msg.body) rows `shouldBe` V.replicate 2 (P.MessageBody (String "fanout"))
      void $ runPgmqSession fixture.pool $ S.dropQueue other

    it "redrives real metadata-disabled writes through a normal handler with the original payload" $ \fixture -> do
      let config =
            (defaultConfig fixture.queueName)
              { batchSize = 1,
                polling = StandardPolling 0.01,
                deadLetterConfig = Just (directDeadLetter fixture.dlqName False)
              }
      produceFailure fixture config (String "no metadata")
      admin <- requireAdmin fixture True
      page <- browseDeadLetters admin fixture.dlqName defaultDlqPageRequest >>= right
      let item = V.head page.items
      entry <- right item.decodedEntry
      entry.originalReadCount `shouldBe` Nothing
      entry.originalHeaders `shouldBe` Nothing
      entry.sourceResolution `shouldBe` PayloadSource
      redriveDeadLetter admin fixture.dlqName item.rawMessage.messageId >>= (`shouldSatisfy` isRedriven)
      -- Run an ordinary handler against the source and observe its public input.
      received <- newEmptyMVar
      outcome <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmq fixture.pool $ runTracingNoop $ do
        adapter <- pgmqAdapter (mkPgmqAdapterEnv fixture.pool) config >>= either (error . show) pure
        app <- runApp defaultAppConfig [(ProcessorId "redriven-input", mkProcessor adapter (\message -> liftIO (putMVar received message.envelope.payload) >> pure AckOk))] >>= either (error . show) pure
        actual <- liftIO $ timeout 5000000 (takeMVar received)
        liftIO $ actual `shouldBe` Just (String "no metadata")
        void $ stopAppGracefully defaultShutdownConfig app
      either throwIO pure outcome

    it "includes source identity for automatic dead-letter moves" $ \fixture -> do
      let config =
            (defaultConfig fixture.queueName)
              { maxRetries = 0,
                batchSize = 1,
                polling = StandardPolling 0.01,
                deadLetterConfig = Just (directDeadLetter fixture.dlqName False)
              }
      produceFailure fixture config (String "automatic")
      admin <- requireAdmin fixture False
      page <- browseDeadLetters admin fixture.dlqName defaultDlqPageRequest >>= right
      entry <- right (V.head page.items).decodedEntry
      entry.reasonCode `shouldBe` "max_retries_exceeded"
      entry.resolvedSource `shouldBe` Just fixture.queueName
      entry.originalReadCount `shouldBe` Nothing

    it "returns a full 500-row page with one lookahead row and an exact boundary" $ \fixture -> do
      ids <- mapM (\_ -> seed fixture (envelope Null)) [1 .. 501 :: Int]
      admin <- requireAdmin fixture False
      page <- browseDeadLetters admin fixture.dlqName (DlqPageRequest 500 Nothing) >>= right
      V.length page.items `shouldBe` 500
      page.nextCursor `shouldBe` Just (DlqCursor fixture.dlqName (ids !! 499))
      next <- browseDeadLetters admin fixture.dlqName (DlqPageRequest 500 page.nextCursor) >>= right
      V.map (\item -> item.rawMessage.messageId) next.items `shouldBe` V.singleton (last ids)
      next.nextCursor `shouldBe` Nothing
  administrativePoolSpec

database :: (TestFixture -> IO ()) -> IO ()
database action = withPgmqDb (\pool -> withTestFixture pool action) >>= either (error . show) pure

right :: (Show e) => Either e a -> IO a
right = either (\err -> expectationFailure (show err) >> fail "expected Right") pure

requireAdmin :: TestFixture -> Bool -> IO DeadLetterAdmin
requireAdmin fixture enabled =
  right $
    mkDeadLetterAdmin fixture.pool $
      (defaultDeadLetterAdminConfig [DlqRegistration fixture.dlqName [fixture.queueName]]) {redriveEnabled = enabled}

awaitDlq :: Pool.Pool -> P.QueueName -> IO ()
awaitDlq pool queue = go (500 :: Int)
  where
    go 0 = expectationFailure "handler did not commit its DLQ move"
    go n = do
      rows <- runPgmqSession pool $ S.peekMessages (Q.PeekMessages (P.queueNameToText queue) Nothing 1)
      if V.null rows then threadDelay 10000 >> go (n - 1) else pure ()

envelope :: Value -> Value
envelope body =
  object
    [ "original_message" .= body,
      "dead_letter_reason_code" .= ("orders.validation.failed" :: Text),
      "dead_letter_reason_detail" .= String "detail"
    ]

putField :: Data.Aeson.Key.Key -> Value -> Value -> Value
putField field value (Object fields) = Object (KM.insert field value fields)
putField _ _ _ = error "expected object fixture"

deleteField :: Data.Aeson.Key.Key -> Value -> Value
deleteField field (Object fields) = Object (KM.delete field fields)
deleteField _ _ = error "expected object fixture"

seed :: TestFixture -> Value -> IO P.MessageId
seed fixture body = runPgmqSession fixture.pool $ S.sendMessage (Q.SendMessage fixture.dlqName (P.MessageBody body) Nothing)

seedWithHeaders :: TestFixture -> Value -> Value -> IO P.MessageId
seedWithHeaders fixture body headers =
  runPgmqSession fixture.pool $
    S.sendMessageWithHeaders (Q.SendMessageWithHeaders fixture.dlqName (P.MessageBody body) (P.MessageHeaders headers) Nothing)

snapshot :: Pool.Pool -> P.QueueName -> IO (V.Vector P.Message)
snapshot pool q = runPgmqSession pool $ S.peekMessages (Q.PeekMessages (P.queueNameToText q) Nothing 10000)

namedQueue :: Text -> P.QueueName
namedQueue = either (error . show) id . P.parseQueueName

isDatabaseError :: Either DlqError a -> Bool
isDatabaseError (Left (DatabaseError _)) = True
isDatabaseError _ = False

isRedriven :: Either DlqError RedriveOutcome -> Bool
isRedriven (Right (Redriven _)) = True
isRedriven _ = False

produceFailure :: TestFixture -> PgmqAdapterConfig -> Value -> IO ()
produceFailure fixture config body = do
  void $ runPgmqSession fixture.pool $ S.sendMessage (Q.SendMessage fixture.queueName (P.MessageBody body) Nothing)
  outcome <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmq fixture.pool $ runTracingNoop $ do
    adapter <- pgmqAdapter (mkPgmqAdapterEnv fixture.pool) config >>= either (error . show) pure
    app <- runApp defaultAppConfig [(ProcessorId "source-identity", mkProcessor adapter (\_ -> pure (AckDeadLetter (InvalidPayload "failed"))))] >>= either (error . show) pure
    liftIO $ awaitDlq fixture.pool fixture.dlqName
    void $ stopAppGracefully defaultShutdownConfig app
  either throwIO pure outcome

administrativePoolSpec :: Spec
administrativePoolSpec = do
  it "scopes statement and lock deadlines to each transaction on a borrowed single-connection pool" $
    withPools $ \fixture adminPool -> do
      admin <- right $ mkDeadLetterAdmin adminPool (defaultDeadLetterAdminConfig [DlqRegistration fixture.dlqName [fixture.queueName]])
      before <- poolSettings adminPool
      messageId <- seed fixture (envelope Null)
      void $ browseDeadLetters admin fixture.dlqName defaultDlqPageRequest >>= right
      void $ fetchDeadLetter admin fixture.dlqName messageId >>= right
      poolSettings adminPool `shouldReturn` before
      rows <- snapshot fixture.pool fixture.dlqName
      let config =
            (defaultDeadLetterAdminConfig [DlqRegistration fixture.dlqName [fixture.queueName]])
              { redriveEnabled = True,
                statementTimeoutMs = 1000,
                lockTimeoutMs = 20
              }
      bounded <- right $ mkDeadLetterAdmin adminPool config
      withLockedQueue fixture.pool fixture.dlqName $ do
        result <- timeout 1000000 (redriveDeadLetter bounded fixture.dlqName messageId)
        result `shouldSatisfy` maybe False isDatabaseError
      poolSettings adminPool `shouldReturn` before
      snapshot fixture.pool fixture.dlqName `shouldReturn` rows
      -- A shorter statement deadline also interrupts read-side lock waits.
      shortStatement <- right $ mkDeadLetterAdmin adminPool (config {statementTimeoutMs = 20, lockTimeoutMs = 1000})
      withLockedQueue fixture.pool fixture.dlqName $ do
        result <- timeout 1000000 (browseDeadLetters shortStatement fixture.dlqName defaultDlqPageRequest)
        result `shouldSatisfy` maybe False isDatabaseError
      poolSettings adminPool `shouldReturn` before
      redriveDeadLetter bounded fixture.dlqName messageId >>= (`shouldSatisfy` isRedriven)
      poolSettings adminPool `shouldReturn` before

  it "lets cancellation escape without a successful absence or a lost DLQ row" $
    withPools $ \fixture adminPool -> do
      admin <-
        right $
          mkDeadLetterAdmin adminPool $
            (defaultDeadLetterAdminConfig [DlqRegistration fixture.dlqName [fixture.queueName]]) {redriveEnabled = True}
      messageId <- seed fixture (envelope (String "cancelled"))
      before <- snapshot fixture.pool fixture.dlqName
      withLockedQueue fixture.pool fixture.dlqName $
        withAsync (redriveDeadLetter admin fixture.dlqName messageId) $ \request -> do
          awaitBlockedRedrive fixture.pool fixture.dlqName
          cancel request
          waitCatch request >>= (`shouldSatisfy` isLeft)
      snapshot fixture.pool fixture.dlqName `shouldReturn` before
      redriveDeadLetter admin fixture.dlqName messageId >>= (`shouldSatisfy` isRedriven)

  it "checks disabled mutations and invalid requests even with an unusable database pool" $ do
    let settings = Settings.connectionString "host=/tmp/plan9-nonexistent-postgres connect_timeout=1"
        config =
          PoolConfig.settings
            [ PoolConfig.size 1,
              PoolConfig.acquisitionTimeout (secondsToDiffTime 1),
              PoolConfig.staticConnectionSettings settings
            ]
        source = namedQueue "source"
        dlq = namedQueue "dlq"
    bracket (Pool.acquire config) Pool.release $ \pool -> do
      admin <- right $ mkDeadLetterAdmin pool (defaultDeadLetterAdminConfig [DlqRegistration dlq [source]])
      redriveDeadLetter admin source (P.MessageId 1) `shouldReturn` Left RedriveDisabled
      browseDeadLetters admin dlq (DlqPageRequest 0 Nothing) `shouldReturn` Left (InvalidPageRequest (InvalidPageLimit 0))
      fetchDeadLetter admin source (P.MessageId 1) `shouldReturn` Left (UnknownManagedDlq source)
      fetchDeadLetter admin dlq (P.MessageId 1) >>= (`shouldSatisfy` isDatabaseError)

withPools :: (TestFixture -> Pool.Pool -> IO ()) -> IO ()
withPools action = withPgmqDbPools 4 1 (\workers admin -> withTestFixture workers (\fixture -> action fixture admin)) >>= either (error . show) pure

poolSettings :: Pool.Pool -> IO (Text, Text)
poolSettings pool =
  runPgmqSession pool $
    Session.statement () $
      Statement.unpreparable
        "select current_setting('statement_timeout'), current_setting('lock_timeout')"
        E.noParams
        (D.singleRow ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

withLockedQueue :: Pool.Pool -> P.QueueName -> IO a -> IO a
withLockedQueue pool q action = do
  ready <- newEmptyMVar
  release <- newEmptyMVar
  let sql statement = Session.statement () (Statement.unpreparable statement E.noParams D.noResult)
      hold = runPgmqSession pool $ do
        sql "begin"
        sql ("lock table pgmq." <> Inspection.quoteIdentifier ("q_" <> P.queueNameToText q) <> " in access exclusive mode")
        liftIO (putMVar ready ())
        liftIO (takeMVar release)
        sql "rollback"
  bracket (async hold) (\worker -> putMVar release () >> void (waitCatch worker)) $ \_ -> do
    acquired <- timeout 5000000 (takeMVar ready)
    acquired `shouldBe` Just ()
    action

-- Wait for the request to be inside its transaction, rather than merely
-- cancelling a thread which might still be acquiring its first connection.
awaitBlockedRedrive :: Pool.Pool -> P.QueueName -> IO ()
awaitBlockedRedrive pool q = go (200 :: Int)
  where
    patternText = "%from pgmq." <> Inspection.quoteIdentifier ("q_" <> P.queueNameToText q) <> "%for update"
    waiting =
      Session.statement patternText $
        Statement.unpreparable
          "select exists(select 1 from pg_stat_activity where wait_event_type = 'Lock' and query like $1)"
          (E.param (E.nonNullable E.text))
          (D.singleRow (D.column (D.nonNullable D.bool)))
    go 0 = expectationFailure "redrive did not reach its row-lock wait"
    go n = do
      blocked <- runPgmqSession pool waiting
      if blocked then pure () else threadDelay 10000 >> go (n - 1)
