module DeadLetterExample (configureOrders, inspectOrders) where

import Hasql.Pool qualified as Pool
import Pgmq.Types (QueueName)
import Shibuya.Adapter.Pgmq.DeadLetter

configureOrders :: Pool.Pool -> QueueName -> QueueName -> Either DlqConfigError DeadLetterAdmin
configureOrders administrativePool source dlq =
  mkDeadLetterAdmin
    administrativePool
    (defaultDeadLetterAdminConfig [DlqRegistration dlq [source]])

inspectOrders :: DeadLetterAdmin -> QueueName -> IO (Either DlqError DeadLetterPage)
inspectOrders admin dlq = browseDeadLetters admin dlq defaultDlqPageRequest
