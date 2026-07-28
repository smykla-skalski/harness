//! Tracked run domain: run models, state, and workflow.
//!
//! This tree has no `#[path]` include anywhere else in the workspace; it
//! moves out of the root `harness` crate purely to give it its own
//! compilation unit, so an edit here no longer forces a full root rebuild.

#![deny(unsafe_code)]

pub mod context;
pub mod prepared_suite;
pub mod report;
pub mod specs;
pub mod status;
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
