---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Released PGMQ client lacks inspection statements](1-released-pgmq-client-lacks-inspection-statements.md) - The latest released pgmq-hasql omits the inspection module required by the administration API, so release-based acceptance cannot run.
- [Incremental Cabal build retains incompatible dependency identities](2-incremental-cabal-build-retains-incompatible-dependency-identities.md) - The reused build directory produced missing effect-handler errors after dependency and optimization changes; a fresh build directory compiled all components.
