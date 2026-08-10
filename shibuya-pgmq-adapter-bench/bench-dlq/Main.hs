module Main (main) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter.Pgmq.Convert (mkDlqPayload)
import Shibuya.Core.Ack
  ( DeadLetterCode,
    DeadLetterReason (..),
    mkDeadLetterCode,
    renderDeadLetterReason,
  )
import Test.Tasty.Bench (bench, bgroup, defaultMain, nf)

main :: IO ()
main = do
  forM_ benchmarkCases $ \(label, reason) -> do
    let legacyLength = LazyByteString.length (encodeLegacyPayload reason)
        dualWriteLength = LazyByteString.length (encodeDualWritePayload reason)
    putStrLn $
      "DLQ-PAYLOAD-BYTES: "
        <> label
        <> " legacy="
        <> show legacyLength
        <> " dualWrite="
        <> show dualWriteLength
        <> " delta="
        <> show (dualWriteLength - legacyLength)
  defaultMain
    [ bgroup
        label
        [ bench "legacy" $ nf encodeLegacyPayload reason,
          bench "dual-write" $ nf encodeDualWritePayload reason
        ]
    | (label, reason) <- benchmarkCases
    ]

benchmarkCases :: [(String, DeadLetterReason)]
benchmarkCases =
  [ ("max-retries", MaxRetriesExceeded),
    ( "representative-application",
      ApplicationFailure representativeDeadLetterCode representativeDetail
    ),
    ( "application-8k-detail",
      ApplicationFailure representativeDeadLetterCode (Text.replicate 8192 "x")
    )
  ]

encodeLegacyPayload :: DeadLetterReason -> LazyByteString.ByteString
encodeLegacyPayload reason =
  encode $
    object
      [ "original_message" .= Pgmq.unMessageBody sampleMessage.body,
        "dead_letter_reason" .= renderDeadLetterReason reason
      ]

encodeDualWritePayload :: DeadLetterReason -> LazyByteString.ByteString
encodeDualWritePayload reason =
  encode $ Pgmq.unMessageBody (mkDlqPayload sampleMessage reason False)

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
