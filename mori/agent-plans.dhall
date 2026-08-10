let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/027403783777cbce0e87eb660a0b3d8119ebe8d2/package.dhall
        sha256:d29ca03286afa92b7589d09b7a6d98ad8e39d11b255a4b8751f3327b0722fba3

let AgentPlans =
      https://raw.githubusercontent.com/shinzui/mori-schema/027403783777cbce0e87eb660a0b3d8119ebe8d2/extensions/agent-plans/package.dhall
        sha256:0b567808087da1924fb121df044c9432f676bb81305d5373809e3182d054943b

in  AgentPlans.AgentPlansCatalog::{
    , plans =
      [ AgentPlans.ExposedPlan::{
        , kind = AgentPlans.PlanKind.ExecPlan
        , file =
            "docs/plans/5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads.md"
        , status = AgentPlans.PlanStatus.InProgress
        , summary = Some
            "Dual-write stable dead-letter codes and details into PGMQ DLQ payloads"
        }
      ]
    }
