-- | Implementation of adapter-owned DLQ semantics and transaction composition.
module Shibuya.Adapter.Pgmq.DeadLetter.Internal where

import Control.Monad (unless, void, when)
import Data.Aeson (FromJSON, Result (..), Value (..), fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Functor.Contravariant (contramap)
import Data.Int (Int32, Int64)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSession
import Pgmq.Effectful (PgmqRuntimeError, fromUsageError)
import Pgmq.Hasql.Decoders (messageDecoder)
import Pgmq.Hasql.Encoders (messageIdValue)
import Pgmq.Hasql.Statements.Inspection qualified as Inspection
import Pgmq.Hasql.Statements.Message qualified as Msg
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (Message (..), MessageBody (..), MessageHeaders (..), MessageId (..), QueueName, parseQueueName, queueNameToText)
import Shibuya.Adapter.Pgmq.Config (DeadLetterConfig (..), DeadLetterTarget (..), PgmqAdapterConfig (..))

-- | One explicitly managed physical DLQ and the sources it may return to.
data DlqRegistration = DlqRegistration
  { deadLetterQueue :: !QueueName,
    allowedSourceQueues :: ![QueueName]
  }
  deriving stock (Eq, Show)

-- | Administrative settings, independent of worker configuration.
data DeadLetterAdminConfig = DeadLetterAdminConfig
  { registrations :: ![DlqRegistration],
    redriveEnabled :: !Bool,
    statementTimeoutMs :: !Int32,
    lockTimeoutMs :: !Int32
  }
  deriving stock (Eq, Show)

-- | Disable mutation; bound each statement to 5 seconds and lock waits to 1.
defaultDeadLetterAdminConfig :: [DlqRegistration] -> DeadLetterAdminConfig
defaultDeadLetterAdminConfig rs = DeadLetterAdminConfig rs False 5000 1000

-- | Invalid configuration is rejected without acquiring a connection.
data DlqConfigError
  = DuplicateManagedQueue !QueueName
  | EmptySourceQueues !QueueName
  | DuplicateSourceQueues !QueueName
  | SelfMapping !QueueName
  | InvalidStatementTimeout !Int32
  | InvalidLockTimeout !Int32
  | NoDirectDeadLetterTarget
  deriving stock (Eq, Show)

-- | Borrowed pool and validated configuration; no threads, queries or ownership.
data DeadLetterAdmin = DeadLetterAdmin !Pool.Pool !DeadLetterAdminConfig

-- | Validate registrations and deadlines without performing I/O. The supplied
-- pool is borrowed; the host remains responsible for its lifetime.
mkDeadLetterAdmin :: Pool.Pool -> DeadLetterAdminConfig -> Either DlqConfigError DeadLetterAdmin
mkDeadLetterAdmin pool config = do
  when (config.statementTimeoutMs <= 0) $ Left (InvalidStatementTimeout config.statementTimeoutMs)
  when (config.lockTimeoutMs <= 0) $ Left (InvalidLockTimeout config.lockTimeoutMs)
  let validate seen registration = do
        let queue = registration.deadLetterQueue
            sources = registration.allowedSourceQueues
        when (queue `elem` seen) $ Left (DuplicateManagedQueue queue)
        when (null sources) $ Left (EmptySourceQueues queue)
        when (sources /= nub sources) $ Left (DuplicateSourceQueues queue)
        when (queue `elem` sources) $ Left (SelfMapping queue)
        pure (queue : seen)
      go _ [] = pure ()
      go seen (r : rs) = validate seen r >>= \next -> go next rs
  go [] config.registrations
  pure (DeadLetterAdmin pool config)

-- | Derive the single-source registration for a direct adapter target.
-- Topic destinations require explicit physical registrations.
registrationFromAdapterConfig :: PgmqAdapterConfig -> Either DlqConfigError DlqRegistration
registrationFromAdapterConfig config = case config.deadLetterConfig of
  Just DeadLetterConfig {dlqTarget = DirectQueue queue}
    | queue /= config.queueName -> Right (DlqRegistration queue [config.queueName])
    | otherwise -> Left (SelfMapping queue)
  _ -> Left NoDirectDeadLetterTarget

-- | Exclusive cursor. IDs have meaning only within this physical queue's lifetime.
data DlqCursor = DlqCursor
  { deadLetterQueue :: !QueueName,
    afterMessageId :: !MessageId
  }
  deriving stock (Eq, Show)

-- | Positive row limit (at most 500), with an optional exclusive cursor.
data DlqPageRequest = DlqPageRequest
  { pageLimit :: !Int32,
    afterCursor :: !(Maybe DlqCursor)
  }
  deriving stock (Eq, Show)

-- | Start at the first ID and return at most 50 rows.
defaultDlqPageRequest :: DlqPageRequest
defaultDlqPageRequest = DlqPageRequest 50 Nothing

-- | Whether reason fields were stored explicitly or inferred from old text.
data ReasonRepresentation = StructuredReason | LegacyReason
  deriving stock (Eq, Show)

-- | How the source was resolved. A multi-source historical row remains unknown.
data SourceResolution = PayloadSource | ConfiguredFallback | SourceUnavailable
  deriving stock (Eq, Show)

-- | Stable, field-specific reasons an envelope cannot be interpreted safely.
data DlqDecodeProblem
  = MissingField
  | WrongType !Text
  | InvalidSourceName !Text
  | SourceNotAllowed !QueueName
  deriving stock (Eq, Show)

-- | The envelope field that could not be interpreted and its typed problem.
data DlqDecodeError = DlqDecodeError
  { field :: !Text,
    problem :: !DlqDecodeProblem
  }
  deriving stock (Eq, Show)

-- | Original delivery metadata and current DLQ metadata are deliberately separate.
-- Missing 'originalHeaders' is 'Nothing'; explicit JSON null is @Just Null@.
data DeadLetterEntry = DeadLetterEntry
  { originalPayload :: !Value,
    reasonCode :: !Text,
    reasonDetail :: !Value,
    reasonRepresentation :: !ReasonRepresentation,
    resolvedSource :: !(Maybe QueueName),
    sourceResolution :: !SourceResolution,
    originalMessageId :: !(Maybe MessageId),
    originalReadCount :: !(Maybe Int64),
    originalEnqueuedAt :: !(Maybe UTCTime),
    originalLastReadAt :: !(Maybe UTCTime),
    originalHeaders :: !(Maybe Value),
    dlqMessageId :: !MessageId,
    dlqReadCount :: !Int64,
    dlqEnqueuedAt :: !UTCTime,
    dlqLastReadAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

-- | Corrupt envelopes stay in their original position and retain their raw row.
data DeadLetterItem = DeadLetterItem
  { deadLetterQueue :: !QueueName,
    rawMessage :: !Message,
    decodedEntry :: !(Either DlqDecodeError DeadLetterEntry)
  }
  deriving stock (Eq, Show)

-- | A moving view, not a shared snapshot. Refresh page one for late lower IDs.
-- The row limit does not bound JSON bytes or database scan work.
data DeadLetterPage = DeadLetterPage
  { items :: !(Vector DeadLetterItem),
    nextCursor :: !(Maybe DlqCursor)
  }
  deriving stock (Eq, Show)

-- | Invalid row limit or a cursor bound to a different physical DLQ.
data DlqPageError = InvalidPageLimit !Int32 | CursorQueueMismatch !QueueName !QueueName
  deriving stock (Eq, Show)

-- | Database failures never become empty pages or successful absence.
data DlqError
  = RedriveDisabled
  | UnknownManagedDlq !QueueName
  | InvalidPageRequest !DlqPageError
  | EntryNotFound !QueueName !MessageId
  | MalformedEnvelope !DlqDecodeError
  | UnresolvedSource
  | DisallowedSource !QueueName
  | DatabaseError !PgmqRuntimeError
  deriving stock (Eq, Show)

-- | Absence cannot establish which actor removed the row.
data RedriveOutcome = Redriven !MessageId | AlreadyAbsent
  deriving stock (Eq, Show)

findRegistration :: DeadLetterAdminConfig -> QueueName -> Either DlqError DlqRegistration
findRegistration config queue = case filter (\r -> r.deadLetterQueue == queue) config.registrations of
  [registration] -> Right registration
  _ -> Left (UnknownManagedDlq queue)

decodeEntry :: DlqRegistration -> Message -> Either DlqDecodeError DeadLetterEntry
decodeEntry registration msg = case unMessageBody msg.body of
  Object fields -> do
    originalPayload <- required fields "original_message"
    (reasonCode, reasonDetail, reasonRepresentation) <- decodeReason fields
    (resolvedSource, sourceResolution) <- case KM.lookup "original_queue" fields of
      Nothing -> pure $ case registration.allowedSourceQueues of
        [source] -> (Just source, ConfiguredFallback)
        _ -> (Nothing, SourceUnavailable)
      Just value -> do
        name <- typed "original_queue" value
        source <- either (const $ bad "original_queue" (InvalidSourceName name)) pure (parseQueueName name)
        unless (source `elem` registration.allowedSourceQueues) $ bad "original_queue" (SourceNotAllowed source)
        pure (Just source, PayloadSource)
    originalMessageId <- fmap MessageId <$> optional fields "original_message_id"
    originalReadCount <- optional fields "read_count"
    originalEnqueuedAt <- optional fields "original_enqueued_at"
    originalLastReadAt <- case KM.lookup "last_read_at" fields of
      Nothing -> pure Nothing
      Just Null -> pure Nothing
      Just value -> Just <$> typed "last_read_at" value
    let originalHeaders = KM.lookup "original_headers" fields
    pure
      DeadLetterEntry
        { originalPayload,
          reasonCode,
          reasonDetail,
          reasonRepresentation,
          resolvedSource,
          sourceResolution,
          originalMessageId,
          originalReadCount,
          originalEnqueuedAt,
          originalLastReadAt,
          originalHeaders,
          dlqMessageId = msg.messageId,
          dlqReadCount = msg.readCount,
          dlqEnqueuedAt = msg.enqueuedAt,
          dlqLastReadAt = msg.lastReadAt
        }
  _ -> bad "$" (WrongType "object")
  where
    decodeReason fields
      | KM.member "dead_letter_reason_code" fields || KM.member "dead_letter_reason_detail" fields = do
          code <- required fields "dead_letter_reason_code" >>= typed "dead_letter_reason_code"
          detail <- required fields "dead_letter_reason_detail"
          pure (code, detail, StructuredReason)
      | otherwise = do
          rendered <- required fields "dead_letter_reason" >>= typed "dead_letter_reason"
          let (code, suffix) = Text.breakOn ": " rendered
          pure (code, if Text.null suffix then Null else String (Text.drop 2 suffix), LegacyReason)
    required fields key = maybe (bad (Key.toText key) MissingField) pure (KM.lookup key fields)
    optional fields key = traverse (typed (Key.toText key)) (KM.lookup key fields)

bad :: Text -> DlqDecodeProblem -> Either DlqDecodeError a
bad field problem = Left DlqDecodeError {field, problem}

typed :: (FromJSON a) => Text -> Value -> Either DlqDecodeError a
typed field value = case fromJSON value of
  Error err -> bad field (WrongType (Text.pack err))
  Success result -> Right result

inspectItem :: DlqRegistration -> Message -> DeadLetterItem
inspectItem registration msg = DeadLetterItem registration.deadLetterQueue msg (decodeEntry registration msg)

-- | Transaction-local settings are reset by PostgreSQL at commit or rollback.
setTimeouts :: DeadLetterAdminConfig -> Tx.Transaction ()
setTimeouts config =
  void $
    Tx.statement
      (Text.pack (show config.statementTimeoutMs) <> "ms", Text.pack (show config.lockTimeoutMs) <> "ms")
      ( Statement.preparable
          "select set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true)"
          (contramap fst (E.param (E.nonNullable E.text)) <> contramap snd (E.param (E.nonNullable E.text)))
          (D.singleRow ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))
      )

runTransaction :: DeadLetterAdmin -> TxSession.Mode -> Tx.Transaction (Either DlqError a) -> IO (Either DlqError a)
runTransaction (DeadLetterAdmin pool config) mode tx = do
  result <- Pool.use pool $ TxSession.transactionNoRetry TxSession.ReadCommitted mode (setTimeouts config >> tx)
  pure $ either (Left . DatabaseError . fromUsageError) id result

resolveTable :: QueueName -> Tx.Transaction Text
resolveTable queue = Tx.statement (queueNameToText queue, "q") Inspection.formatTableName

-- | Observe rows without leasing, including invisible and malformed rows.
browseDeadLetters :: DeadLetterAdmin -> QueueName -> DlqPageRequest -> IO (Either DlqError DeadLetterPage)
browseDeadLetters admin@(DeadLetterAdmin _ config) queue request = case validate of
  Left err -> pure (Left err)
  Right registration -> runTransaction admin TxSession.Read $ do
    table <- resolveTable queue
    rows <- Tx.statement (fmap (\cursor -> cursor.afterMessageId) request.afterCursor, request.pageLimit + 1) (Inspection.peekStatement table)
    let page = Vector.take (fromIntegral request.pageLimit) rows
        cursor =
          if Vector.length rows > fromIntegral request.pageLimit
            then (\msg -> DlqCursor queue msg.messageId) <$> (page Vector.!? (Vector.length page - 1))
            else Nothing
    pure $ Right (DeadLetterPage (Vector.map (inspectItem registration) page) cursor)
  where
    validate = do
      registration <- findRegistration config queue
      when (request.pageLimit < 1 || request.pageLimit > 500) $
        Left (InvalidPageRequest (InvalidPageLimit request.pageLimit))
      case request.afterCursor of
        Just cursor | cursor.deadLetterQueue /= queue -> Left (InvalidPageRequest (CursorQueueMismatch queue cursor.deadLetterQueue))
        _ -> pure ()
      pure registration

-- | Observe one registered DLQ row without leasing it. Malformed rows are
-- returned as inspectable items; only actual absence yields EntryNotFound.
fetchDeadLetter :: DeadLetterAdmin -> QueueName -> MessageId -> IO (Either DlqError DeadLetterItem)
fetchDeadLetter admin@(DeadLetterAdmin _ config) queue messageId = case findRegistration config queue of
  Left err -> pure (Left err)
  Right registration -> runTransaction admin TxSession.Read $ do
    table <- resolveTable queue
    result <- Tx.statement messageId (Inspection.lookupStatement table)
    pure $ maybe (Left (EntryNotFound queue messageId)) (Right . inspectItem registration) result

-- | Serialize on the selected row and atomically delete/send its original body.
-- Retry the complete operation after uncertain commit. A new ID/count/time and
-- tail position are assigned; distinct fan-out copies have distinct claims.
redriveDeadLetter :: DeadLetterAdmin -> QueueName -> MessageId -> IO (Either DlqError RedriveOutcome)
redriveDeadLetter admin@(DeadLetterAdmin _ config) queue messageId
  | not config.redriveEnabled = pure (Left RedriveDisabled)
  | otherwise = case findRegistration config queue of
      Left err -> pure (Left err)
      Right registration -> runTransaction admin TxSession.Write $ do
        table <- resolveTable queue
        locked <- Tx.statement messageId (lockedLookup table)
        case locked of
          Nothing -> pure (Right AlreadyAbsent)
          Just msg -> case decodeEntry registration msg of
            Left err -> pure $ Left $ case err.problem of
              SourceNotAllowed source -> DisallowedSource source
              _ -> MalformedEnvelope err
            Right entry -> case entry.resolvedSource of
              Nothing -> pure (Left UnresolvedSource)
              Just source -> do
                claimed <- Tx.statement (Q.MessageQuery queue messageId) Msg.deleteMessage
                if not claimed
                  then pure (Right AlreadyAbsent)
                  else do
                    let headers = case entry.originalHeaders of
                          Just saved -> Just saved
                          Nothing -> msg.headers
                    newId <- case headers of
                      Nothing -> Tx.statement (Q.SendMessage source (MessageBody entry.originalPayload) Nothing) Msg.sendMessage
                      Just value -> Tx.statement (Q.SendMessageWithHeaders source (MessageBody entry.originalPayload) (MessageHeaders value) Nothing) Msg.sendMessageWithHeaders
                    pure (Right (Redriven newId))

lockedLookup :: Text -> Statement.Statement MessageId (Maybe Message)
lockedLookup table =
  Statement.unpreparable
    ( "select msg_id, read_ct, enqueued_at, last_read_at, vt, message, headers from pgmq."
        <> Inspection.quoteIdentifier table
        <> " where msg_id = $1 for update"
    )
    (E.param (E.nonNullable messageIdValue))
    (D.rowMaybe messageDecoder)
