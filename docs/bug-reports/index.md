---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Long polls can starve acknowledgements on a shared pool](long-polls-starve-acknowledgements-on-a-shared-pool.md) - Two long-polling processors using a two-connection pool handle their messages but leave both acknowledgements pending until shutdown.
