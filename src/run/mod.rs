//! Tracked run domain: run models, state, workflow, audit, and commands.

pub(crate) mod application;
pub mod args;
pub(crate) mod audit;
pub(crate) mod commands;
pub mod context;
pub mod prepared_suite;
pub mod report;
pub(crate) mod report_policy;
pub(crate) mod resolve;
pub(crate) mod services;
pub mod specs;
pub mod state_capture;
pub mod status;
pub mod workflow;

pub use application::RunApplication;
pub use args::RunDirArgs;
pub use commands::{
    ApiArgs, ApiMethod, ApplyArgs, CaptureArgs, CloseoutArgs, ClusterCheckArgs, DiffArgs,
    DoctorArgs, EnvoyArgs, EnvoyCommand, FinishArgs, InitArgs, KumaArgs, KumaCommand, KumactlArgs,
    KumactlCommand, LogsArgs, PreflightArgs, RecordArgs, RepairArgs, ReportArgs, ReportCommand,
    RestartNamespaceArgs, ResumeArgs, RunnerStateArgs, ServiceArgs, StartArgs, StatusArgs,
    TaskArgs, TaskCommand, TokenArgs, ValidateArgs,
};
pub use context::{
    CleanupManifest, CleanupResource, RunAggregate, RunContext, RunLayout, RunMetadata,
    RunRepository, RunRepositoryPort,
};
pub use prepared_suite::{PreparedSuiteArtifact, PreparedSuitePlan};
pub use report::{GroupVerdict, RunReport, RunReportFrontmatter, Verdict};
pub use specs::{
    GroupFrontmatter, GroupSection, GroupSpec, HelmValueEntry, SuiteFrontmatter, SuiteSpec,
};
pub use status::{ExecutedGroupChange, ExecutedGroupRecord, RunCounts, RunStatus};
