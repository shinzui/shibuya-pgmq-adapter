let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in S.Blueprint::{
  , name = "shibuya-pgmq-adapter-upgrade"
  , version = Some "0.1.0"
  , description = Some "Upgrade guidance for released PGMQ adapter configuration and processing trace changes"
  , prompt = ./prompt.md as Text
  , versionProbe = Some "jq -r '.\"install-plan\"[] | select(.\"pkg-name\"==\"shibuya-pgmq-adapter\") | .\"pkg-version\"' dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep ."
  , allowedTools = Some [ "Bash(cabal *)", "Bash(rg *)" ]
  , migrations = [ S.BlueprintMigration::{
      , from = "0.18.0.0"
      , to = "0.19.0.0"
      , prompt = ./migrations/0.18.0.0-to-0.19.0.0.md as Text
      } ]
  , tags = [ "haskell", "postgresql", "shibuya", "opentelemetry", "migration" ]
  }
