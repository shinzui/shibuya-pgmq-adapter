{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}

-- | Benchmark-only monotonic clock. Darwin CLOCK_MONOTONIC in the bundled
-- runtime quantizes these observations to microseconds. Read raw monotonic time instead
-- so a 10% latency budget on a ~30us operation is not decided by rounding ticks.
module PerformanceClock (getMonotonicTimeNSec, clockName) where

#ifdef darwin_HOST_OS
import Data.Word (Word64)
import Foreign.C.Types (CInt (..))

foreign import capi unsafe "time.h value CLOCK_MONOTONIC_RAW"
  clockMonotonicRaw :: CInt

foreign import capi unsafe "time.h clock_gettime_nsec_np"
  clockNsec :: CInt -> IO Word64

getMonotonicTimeNSec :: IO Word64
getMonotonicTimeNSec = do
  value <- clockNsec clockMonotonicRaw
  if value == 0 then error "raw monotonic clock failed" else pure value

clockName :: String
clockName = "clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)"
#else
import GHC.Clock (getMonotonicTimeNSec)

clockName :: String
clockName = "GHC.Clock.getMonotonicTimeNSec"
#endif
