//! Tracked run domain: run models, state, workflow, audit, and commands.

pub mod args;
pub mod audit;
pub mod commands;
pub mod context;
pub mod prepared_suite;
pub(crate) mod report_policy;
pub mod resolve;
pub mod services;
pub mod state_capture;
pub mod workflow;

pub use args::RunDirArgs;
pub use context::{
    CleanupManifest, CleanupResource, RunAggregate, RunContext, RunLayout, RunMetadata,
    RunRepository, RunRepositoryPort,
};
pub use prepared_suite::{PreparedSuiteArtifact, PreparedSuitePlan};
pub use services::RunServices;
