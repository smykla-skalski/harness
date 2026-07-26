//! Tracked run domain: run models, state, workflow, and audit.

pub(crate) mod application;
pub(crate) mod audit;
pub mod context;
pub mod prepared_suite;
pub mod report;
pub mod specs;
pub mod status;
#[cfg(test)]
pub(crate) mod test_support;
pub mod workflow;

pub use context::{
    CleanupManifest, CleanupResource, RunAggregate, RunContext, RunLayout, RunMetadata,
    RunRepository, RunRepositoryPort,
};
pub use prepared_suite::{PreparedSuiteArtifact, PreparedSuitePlan};
pub use report::{GroupVerdict, Verdict};
pub use specs::{
    GroupFrontmatter, GroupSection, GroupSpec, HelmValueEntry, SuiteFrontmatter, SuiteSpec,
};
pub use status::{ExecutedGroupChange, ExecutedGroupRecord, RunCounts, RunStatus};
