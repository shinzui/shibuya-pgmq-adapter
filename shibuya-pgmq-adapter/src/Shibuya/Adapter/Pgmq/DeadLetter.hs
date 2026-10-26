-- | In-process administration for explicitly registered adapter-managed DLQs.
--
-- Supply a separate administrative pool connected to the workers' database.
-- Constructing a handle performs no I/O and starts no background work. The host
-- owns and closes the pool. Separate connections do not isolate database CPU,
-- I/O or locks. Host transports must enforce their own caller permissions;
-- 'redriveEnabled' is a mutation gate, not authentication.
--
-- Pages are moving views ordered by queue-local message ID. Restart at the first
-- page to discover lower IDs committed late. Limits bound rows, not JSON bytes.
-- Archive recovery and queue discovery/creation are outside this API.
module Shibuya.Adapter.Pgmq.DeadLetter
  ( DeadLetterAdmin,
    DeadLetterAdminConfig (..),
    defaultDeadLetterAdminConfig,
    DlqRegistration (..),
    registrationFromAdapterConfig,
    DlqConfigError (..),
    mkDeadLetterAdmin,
    DlqCursor (..),
    DlqPageRequest (..),
    defaultDlqPageRequest,
    DeadLetterPage (..),
    DeadLetterItem (..),
    DeadLetterEntry (..),
    ReasonRepresentation (..),
    SourceResolution (..),
    DlqDecodeError (..),
    DlqDecodeProblem (..),
    DlqPageError (..),
    DlqError (..),
    RedriveOutcome (..),
    browseDeadLetters,
    fetchDeadLetter,
    redriveDeadLetter,
  )
where

import Shibuya.Adapter.Pgmq.DeadLetter.Internal
