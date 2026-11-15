{ repoName = "shibuya-pgmq-adapter"
, repoDescription = Some
    "PGMQ adapter for Shibuya"
, modules =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, recipes =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, blueprints =
  [ { name = "shibuya-pgmq-adapter-upgrade"
    , version = Some "0.1.0"
    , path = "blueprints/shibuya-pgmq-adapter-upgrade"
    , description = Some "Upgrade guidance for released PGMQ adapter configuration and trace contracts"
    , tags = [ "haskell", "postgresql", "shibuya", "migration" ]
    }
  ]
, prompts =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
}
