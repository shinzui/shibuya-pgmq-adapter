module Main (main) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter.Pgmq.Convert (mkDlqPayload, mkDlqPayloadForQueue)
import Shibuya.Core.Ack
  ( DeadLetterCode,
    DeadLetterReason (..),
    mkDeadLetterCode,
  )
import Test.Tasty.Bench (bench, bgroup, defaultMain, nf)

main :: IO ()
main = do
  forM_ cases $ \(label, message, reason, metadata) -> do
    let existing = encodePayload False metadata reason message
        queueAware = encodePayload True metadata reason message
        delta = LazyByteString.length queueAware - LazyByteString.length existing
        sourceBytes = LazyByteString.length (encode (object ["original_queue" .= Pgmq.queueNameToText sourceQueue])) - 1
    if delta /= sourceBytes then error "original_queue encoded size did not match its field contribution" else pure ()
    putStrLn
      ( "DLQ-PAYLOAD-BYTES: "
          <> label
          <> " current="
          <> show (LazyByteString.length existing)
          <> " queueAware="
          <> show (LazyByteString.length queueAware)
          <> " sourceFieldBytes="
          <> show sourceBytes
      )
  defaultMain
    [ bgroup
        label
        [ bench "current" $ nf (encodePayload False metadata reason) message,
          bench "queue-aware" $ nf (encodePayload True metadata reason) message
        ]
    | (label, message, reason, metadata) <- cases
    ]

cases :: [(String, Pgmq.Message, DeadLetterReason, Bool)]
cases =
  [ ( label <> "/body-" <> show bytes <> "/metadata-" <> show metadata,
      sampleMessage {Pgmq.body = Pgmq.MessageBody (String (Text.replicate (bytes - 2) "x"))},
      reason,
      metadata
    )
  | (label, reason) <- benchmarkCases,
    bytes <- [100, 10000, 100000],
    metadata <- [False, True]
  ]

sourceQueue :: Pgmq.QueueName
sourceQueue = either (error . show) id (Pgmq.parseQueueName "orders")

encodePayload :: Bool -> Bool -> DeadLetterReason -> Pgmq.Message -> LazyByteString.ByteString
encodePayload queueAware metadata reason message =
  encode $
    Pgmq.unMessageBody $
      if queueAware
        then mkDlqPayloadForQueue sourceQueue message reason metadata
        else mkDlqPayload message reason metadata

benchmarkCases :: [(String, DeadLetterReason)]
benchmarkCases =
  [ ("poison-pill", PoisonPill "corrupt"),
    ("invalid-payload", InvalidPayload "invalid"),
    ("max-retries", MaxRetriesExceeded),
    ( "representative-application",
      ApplicationFailure representativeDeadLetterCode representativeDetail
    ),
    ( "application-8k-detail",
      ApplicationFailure representativeDeadLetterCode (Text.replicate 8192 "x")
    )
  ]

sampleMessage :: Pgmq.Message
sampleMessage =
  Pgmq.Message
    { messageId = Pgmq.MessageId 42,
      visibilityTime = sampleTime,
      enqueuedAt = sampleTime,
      lastReadAt = Just sampleTime,
      readCount = 5,
      body = Pgmq.MessageBody (String "application-failure"),
      headers = Nothing
    }

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 8 10) 0

representativeDetail :: Text
representativeDetail = "selected 101 recipients; configured limit is 100"

representativeDeadLetterCode :: DeadLetterCode
representativeDeadLetterCode =
  case mkDeadLetterCode "keiro.router.selection.recipient_overflow" of
    Left err -> error (Text.unpack err)
    Right code -> code
