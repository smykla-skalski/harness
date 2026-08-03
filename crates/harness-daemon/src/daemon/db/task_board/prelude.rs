//! Single import point for every task-board query extension trait.
//!
//! `AsyncDaemonDb` no longer carries inherent forwards for these methods --
//! each lives only on its trait, so any caller needs the right trait in scope
//! to call it by name. Glob-importing this module (`use
//! super::db::task_board::prelude::*;` or the crate-root equivalent) brings
//! all of them into scope at once, so a caller never has to track which
//! specific trait backs which method, and a new trait only needs adding here
//! once rather than at every call site that ends up needing it.

pub(crate) use super::dispatch_admission_queries::DispatchAdmissionQueries;
pub(crate) use super::import_lifecycle_queries::ImportLifecycleQueries;
pub(crate) use super::item_core_queries::ItemCoreQueries;
pub(crate) use super::lane_placement_queries::LanePlacementQueries;
pub(crate) use super::orchestrator_settings_queries::OrchestratorSettingsQueries;
pub(crate) use super::policy_runtime_queries::PolicyRuntimeQueries;
pub(crate) use super::project_registry_queries::ProjectRegistryQueries;
pub(crate) use super::provider_queries::ProviderQueries;
pub(crate) use super::remote_assignment_authority_queries::RemoteAssignmentAuthorityQueries;
pub(crate) use super::remote_assignment_controller_scan::RemoteAssignmentControllerScanQueries;
pub(crate) use super::remote_assignment_executor_lifecycle_queries::RemoteAssignmentExecutorLifecycleQueries;
pub(crate) use super::remote_assignment_lease::RemoteAssignmentLeaseQueries;
pub(crate) use super::remote_assignment_lifecycle_owner::RemoteAssignmentLifecycleOwnerQueries;
pub(crate) use super::remote_assignment_offer::RemoteAssignmentOfferQueries;
pub(crate) use super::remote_assignment_recovery::RemoteAssignmentRecoveryQueries;
pub(crate) use super::remote_assignment_start_settlement_queries::RemoteAssignmentStartSettlementQueries;
pub(crate) use super::remote_assignment_status::RemoteAssignmentStatusQueries;
pub(crate) use super::remote_assignment_terminal::RemoteAssignmentTerminalQueries;
pub(crate) use super::remote_execution_queries::RemoteExecutionQueries;
pub(crate) use super::remote_hosts::RemoteHostQueries;
pub(crate) use super::remote_outbound_sources::RemoteOutboundSourceQueries;
pub(crate) use super::remote_result_import::RemoteResultImportQueries;
pub(crate) use super::remote_source_bundle_queries::RemoteSourceBundleQueries;
pub(crate) use super::scheduler::queries::TaskBoardAutomationSchedulerQueries;
pub(crate) use super::triage_queries::TriageQueries;
pub(crate) use super::workflow_execution_queries::WorkflowExecutionQueries;
