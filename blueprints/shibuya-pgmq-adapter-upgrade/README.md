# shibuya-pgmq-adapter-upgrade

Version 0.1.0. Install from this repository with Seihou and run
`seihou agent migrate shibuya-pgmq-adapter-upgrade --from 0.18.0.0 --to 0.19.0.0`.
The 0.18 → 0.19 edge covers strict telemetry configuration, correlation policies
and the Shibuya 0.13 processing span contract. Validate with
`seihou validate-blueprint blueprints/shibuya-pgmq-adapter-upgrade`.
