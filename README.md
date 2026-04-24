# shibuya-pgmq-adapter

PostgreSQL message queue adapter for the [Shibuya](https://github.com/shinzui/shibuya) queue-processing framework.

Integrates with [pgmq](https://github.com/pgmq/pgmq) via [`pgmq-hs`](https://github.com/shinzui/pgmq-hs). Provides visibility-timeout-based leasing, automatic retry handling, optional dead-letter queue support, and OpenTelemetry tracing aligned with messaging semantic-conventions v1.24.

## Packages

- `shibuya-pgmq-adapter` — the adapter library (`Shibuya.Adapter.Pgmq`, `.Config`, `.Convert`).
- `shibuya-pgmq-adapter-bench` — `tasty-bench` micro-benchmarks covering send/read/ack/FIFO/multi-queue/throughput/concurrency plus a raw `pgmq-hasql` comparison.
- `shibuya-pgmq-example` — runnable demo with a `shibuya-pgmq-simulator` and a `shibuya-pgmq-consumer` that uses multiple processors (orders / payments / notifications) with OpenTelemetry and Prometheus metrics.

## Building

The repo ships a Nix flake and `direnv` config for a reproducible toolchain that includes PostgreSQL.

```sh
direnv allow            # or: nix develop
just process-up         # starts postgres + creates database
cabal build all
cabal test shibuya-pgmq-adapter-test
```

## Running the example

```sh
just process-up
cabal run shibuya-pgmq-consumer
cabal run shibuya-pgmq-simulator -- --queue orders --count 10
```

## Layout

```
shibuya-pgmq-adapter/         library sources and tests
shibuya-pgmq-adapter-bench/   tasty-bench micro-benchmarks + endurance
shibuya-pgmq-example/         runnable simulator + consumer
docs/                         user docs and execution plans
mori.dhall                    project manifest (mori registry)
```

## License

MIT. See package `cabal` files for details.
