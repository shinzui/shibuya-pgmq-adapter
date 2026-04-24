let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/9b1d6eea8027ae57576cf0712c0b9167fccbc1a9/package.dhall
        sha256:a19f5dd9181db28ba7a6a1b77b5ab8715e81aba3e2a8f296f40973003a0b4412

let emptyRuntime = { deployable = False, exposesApi = False }

let emptyDeps = [] : List Schema.Dependency

let emptyDocs = [] : List Schema.DocRef.Type

let emptyConfig = [] : List Schema.ConfigItem.Type

in  Schema.Project::{ project =
      Schema.ProjectIdentity::{ name = "shibuya-pgmq-adapter"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some
          "PGMQ adapter for the Shibuya queue processing framework"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Active
      , domains = [ "concurrency", "queue-processing", "postgresql" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{ name = "shibuya-pgmq-adapter"
        , github = Some "shinzui/shibuya-pgmq-adapter"
        , localPath = Some "."
        }
      ]
    , packages =
      [ Schema.Package::{ name = "shibuya-pgmq-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-adapter"
        , description = Some
            "PGMQ adapter with visibility timeout leasing, retry handling, and DLQ support"
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "shinzui/pgmq-hs"
          , Schema.Dependency.ByName "hasql/hasql"
          , Schema.Dependency.ByName "shinzui/shibuya"
          , Schema.Dependency.ByName "composewell/streamly"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , Schema.Package::{ name = "shibuya-pgmq-adapter-bench"
        , type = Schema.PackageType.Other "Benchmark"
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-adapter-bench"
        , description = Some
            "Throughput and concurrency benchmarks for the PGMQ adapter"
        , visibility = Schema.Visibility.Internal
        , runtime = emptyRuntime
        , dependencies =
          [ Schema.Dependency.ByName "Bodigrim/tasty-bench"
          ]
        , docs = emptyDocs
        , config = emptyConfig
        }
      , Schema.Package::{ name = "shibuya-pgmq-example"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "shibuya-pgmq-example"
        , description = Some
            "Runnable example with PGMQ, OpenTelemetry tracing, and Prometheus metrics"
        , visibility = Schema.Visibility.Internal
        , runtime = { deployable = True, exposesApi = True }
        , dependencies = emptyDeps
        , docs = emptyDocs
        , config = emptyConfig
        }
      ]
    , dependencies =
      [ "shinzui/shibuya"
      , "effectful/effectful"
      , "composewell/streamly"
      , "shinzui/pgmq-hs"
      , "hasql/hasql"
      , "iand675/hs-opentelemetry"
      , "Bodigrim/tasty-bench"
      ]
    , agents =
      [ Schema.AgentHint::{ role = "adapter-dev"
        , description = Some
            "PGMQ adapter development: leasing, retries, DLQ, tracing"
        , includePaths =
          [ "shibuya-pgmq-adapter/src/**"
          , "shibuya-pgmq-adapter/test/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-pgmq-adapter"
          ]
        }
      , Schema.AgentHint::{ role = "bench-dev"
        , description = Some
            "Benchmark development: tasty-bench suites and endurance harness"
        , includePaths =
          [ "shibuya-pgmq-adapter-bench/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-pgmq-adapter-bench"
          ]
        }
      , Schema.AgentHint::{ role = "examples-dev"
        , description = Some
            "Example app development: simulator + consumer"
        , includePaths =
          [ "shibuya-pgmq-example/**"
          ]
        , excludePaths =
          [ "dist-newstyle/**"
          ]
        , relatedPackages =
          [ "shibuya-pgmq-example"
          ]
        }
      ]
    , docs =
      [ Schema.DocRef::{ key = "readme"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some "Project README with quickstart"
        , location = Schema.DocLocation.LocalFile "README.md"
        }
      , Schema.DocRef::{ key = "changelog"
        , kind = Schema.DocKind.Notes
        , audience = Schema.DocAudience.User
        , description = Some "Release changelog"
        , location = Schema.DocLocation.LocalFile "CHANGELOG.md"
        }
      , Schema.DocRef::{ key = "plans"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.Internal
        , description = Some "Execution plans for adapter development"
        , location = Schema.DocLocation.LocalDir "docs/plans"
        }
      , Schema.DocRef::{ key = "hackage"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.API
        , description = Some "Hackage package page"
        , location =
            Schema.DocLocation.Url
              "https://hackage.haskell.org/package/shibuya-pgmq-adapter"
        }
      ]
    }
