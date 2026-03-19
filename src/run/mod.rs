//! Tracked run domain: run models, state, workflow, audit, and commands.

pub mod args;
pub mod audit;
pub mod commands;
pub mod context;
pub mod prepared_suite;
pub(crate) mod report_policy;
pub mod report;
pub mod resolve;
pub mod services;
pub mod specs;
pub mod state_capture;
pub mod status;
pub mod workflow;

pub use args::RunDirArgs;
pub use context::{
    CleanupManifest, CleanupResource, RunAggregate, RunContext, RunLayout, RunMetadata,
    RunRepository, RunRepositoryPort,
};
pub use prepared_suite::{PreparedSuiteArtifact, PreparedSuitePlan};
pub use report::{GroupVerdict, RunReport, RunReportFrontmatter, Verdict};
pub use services::RunServices;
pub use specs::{
    GroupFrontmatter, GroupSection, GroupSpec, HelmValueEntry, SuiteFrontmatter, SuiteSpec,
};
pub use status::{ExecutedGroupChange, ExecutedGroupRecord, RunCounts, RunStatus};
