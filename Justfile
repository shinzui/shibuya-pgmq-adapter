default:
  just --list

# --- Services ---

[group("services")]
process-up:
  process-compose --tui=false --unix-socket .dev/process-compose.sock up

[group("services")]
process-down:
  process-compose --unix-socket .dev/process-compose.sock down || true

# --- Database ---

[group("database")]
create-database:
  psql -lqt | cut -d \| -f 1 | grep -qw $PGDATABASE || createdb $PGDATABASE

[group("database")]
psql:
  psql $PGDATABASE

[group("database")]
drop-database:
  dropdb --if-exists $PGDATABASE

[group("database")]
reset-database: drop-database create-database

# --- Build ---

[group("build")]
build:
  cabal build all

[group("build")]
test:
  cabal test shibuya-pgmq-adapter-test

[group("build")]
bench:
  cabal bench shibuya-pgmq-adapter-bench

[group("build")]
example-simulator:
  cabal run shibuya-pgmq-simulator

[group("build")]
example-consumer:
  cabal run shibuya-pgmq-consumer

[group("build")]
fmt:
  nix fmt
