//! Task-board wire types, relocated here from `harness-task-board` (#1145).
//!
//! `harness-daemon`'s `daemon::protocol::task_board` re-exports 12 named
//! types from `harness-task-board`, thinned to pure data by #1058's
//! `TaskBoardOrchestratorStatus`/`PolicyPipelinePromoteResponse` redesign.
//! Most of those 12 reach other `harness-task-board`-owned types directly
//! (automation settings, GitHub project config, orchestrator status/workflow
//! enums), so their full pure-data closure had to move alongside them for
//! the same reason #1056 and #1067 already moved their own closures here:
//! `harness-task-board` depends on `harness-protocol`, so this crate cannot
//! depend back on it, and a type embedding one still defined downstream
//! could not move without cycling.
//!
//! `harness-task-board` re-exports every name below unchanged, at the same
//! module paths it used to define them at, so this move changes no public
//! API. A handful of inherent methods and `From` impls that reached
//! task-board-only state (the `harness_session` service layer, the full
//! `TaskBoardItem` domain entity, the policy-compiler engine) could not come
//! along for the same reason those crates cannot depend on `harness-protocol`
//! reaching back into `harness-task-board`; those became free functions in
//! `harness-task-board` instead. See each submodule's own doc comment for
//! the specific ones and why.

pub mod automation_settings;
pub mod automation_snapshot;
pub mod dispatch;
pub mod dispatch_lifecycle;
pub mod evaluation;
pub mod external;
pub mod github_config;
pub mod item_fields;
pub mod item_intent;
pub mod orchestrator;
pub mod orchestrator_status;
pub mod orchestrator_workflow;
pub mod planning;
pub mod policy_decision;
pub mod policy_pipeline;
pub mod policy_scope;
pub mod runtime_config;
pub mod summary;
pub mod types;
