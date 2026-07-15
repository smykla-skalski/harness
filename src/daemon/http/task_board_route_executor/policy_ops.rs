use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    PolicyApprovalGrantRevokeRequest, PolicyApprovalGrantRevokeResponse,
    PolicyApprovalGrantResolveRequest, PolicyApprovalGrantResolveResponse,
    PolicyApprovalGrantsListResponse, PolicyCanvasCreateRequest, PolicyCanvasDeleteRequest,
    PolicyCanvasDuplicateRequest, PolicyCanvasExportRequest, PolicyCanvasExportResponse,
    PolicyCanvasImportRequest, PolicyCanvasImportResponse, PolicyCanvasRenameRequest,
    PolicyCanvasSetActiveRequest, PolicyCanvasSetGlobalEnforcementRequest,
    PolicyCanvasSetSpawnKillSwitchRequest, PolicyCanvasSetSpawnRequiresLivePolicyRequest,
    PolicyCanvasWorkspaceResponse, PolicyPipelineAuditRequest, PolicyPipelineAuditResponse,
    PolicyPipelineGetRequest, PolicyPipelineGoLiveDiffRequest, PolicyPipelineGoLiveDiffResponse,
    PolicyPipelineMakeLiveRequest, PolicyPipelineMakeLiveResponse, PolicyPipelinePromoteRequest,
    PolicyPipelinePromoteResponse, PolicyPipelineReplayRequest, PolicyPipelineReplayResponse,
    PolicyPipelineResponse, PolicyPipelineSaveDraftRequest, PolicyPipelineSaveDraftResponse,
    PolicyPipelineSimulateRequest, PolicyPipelineSimulationResponse, PolicyScenarioCreateRequest,
    PolicyScenarioDeleteRequest, PolicyScenarioUpdateRequest, PolicyTransferBundle,
    PolicyTransferDumpRequest, PolicyTransferImportRequest,
};
use crate::daemon::service;
use crate::errors::CliError;

pub(crate) async fn policy_canvas_workspace(
    db: &AsyncDaemonDb,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::policy_canvas_workspace(db).await
}

pub(crate) async fn create_policy_canvas(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasCreateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::create_policy_canvas(db, request).await
}

pub(crate) async fn duplicate_policy_canvas(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasDuplicateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::duplicate_policy_canvas(db, request).await
}

pub(crate) async fn rename_policy_canvas(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasRenameRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::rename_policy_canvas(db, request).await
}

pub(crate) async fn set_active_policy_canvas(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasSetActiveRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::set_active_policy_canvas(db, request).await
}

pub(crate) async fn delete_policy_canvas(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasDeleteRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::delete_policy_canvas(db, request).await
}

pub(crate) async fn set_policy_canvas_global_enforcement(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasSetGlobalEnforcementRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::set_policy_canvas_global_enforcement(db, request).await
}

pub(crate) async fn set_policy_canvas_spawn_requires_live_policy(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasSetSpawnRequiresLivePolicyRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::set_policy_canvas_spawn_requires_live_policy(db, request).await
}

pub(crate) async fn set_policy_canvas_spawn_kill_switch(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasSetSpawnKillSwitchRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::set_policy_canvas_spawn_kill_switch(db, request).await
}

pub(crate) async fn list_policy_approval_grants(
    db: &AsyncDaemonDb,
) -> Result<PolicyApprovalGrantsListResponse, CliError> {
    service::list_policy_approval_grants(db).await
}

pub(crate) async fn resolve_policy_approval_grant(
    db: &AsyncDaemonDb,
    request: &PolicyApprovalGrantResolveRequest,
) -> Result<PolicyApprovalGrantResolveResponse, CliError> {
    service::resolve_policy_approval_grant(db, request).await
}

pub(crate) async fn revoke_policy_approval_grant(
    db: &AsyncDaemonDb,
    request: &PolicyApprovalGrantRevokeRequest,
) -> Result<PolicyApprovalGrantRevokeResponse, CliError> {
    service::revoke_policy_approval_grant(db, request).await
}

pub(crate) async fn policy_pipeline(
    db: &AsyncDaemonDb,
    request: &PolicyPipelineGetRequest,
) -> Result<PolicyPipelineResponse, CliError> {
    service::policy_pipeline(db, request).await
}

pub(crate) async fn save_policy_pipeline_draft(
    db: &AsyncDaemonDb,
    request: &PolicyPipelineSaveDraftRequest,
) -> Result<PolicyPipelineSaveDraftResponse, CliError> {
    service::save_policy_pipeline_draft(db, request).await
}

pub(crate) async fn simulate_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &PolicyPipelineSimulateRequest,
) -> Result<PolicyPipelineSimulationResponse, CliError> {
    service::simulate_policy_pipeline(db, request).await
}

pub(crate) async fn promote_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &PolicyPipelinePromoteRequest,
) -> Result<PolicyPipelinePromoteResponse, CliError> {
    service::promote_policy_pipeline(db, request).await
}

pub(crate) async fn make_live_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &PolicyPipelineMakeLiveRequest,
) -> Result<PolicyPipelineMakeLiveResponse, CliError> {
    service::make_live_policy_pipeline(db, request).await
}

pub(crate) async fn go_live_diff_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &PolicyPipelineGoLiveDiffRequest,
) -> Result<PolicyPipelineGoLiveDiffResponse, CliError> {
    service::go_live_diff_policy_pipeline(db, request).await
}

pub(crate) async fn replay_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &PolicyPipelineReplayRequest,
) -> Result<PolicyPipelineReplayResponse, CliError> {
    service::replay_policy_pipeline(db, request).await
}

pub(crate) async fn audit_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &PolicyPipelineAuditRequest,
) -> Result<PolicyPipelineAuditResponse, CliError> {
    service::audit_policy_pipeline(db, request).await
}

pub(crate) async fn export_policy_canvas(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasExportRequest,
) -> Result<PolicyCanvasExportResponse, CliError> {
    service::export_policy(db, request).await
}

pub(crate) async fn import_policy_canvas(
    db: &AsyncDaemonDb,
    request: &PolicyCanvasImportRequest,
) -> Result<PolicyCanvasImportResponse, CliError> {
    service::import_policy(db, request).await
}

pub(crate) async fn dump_policy_transfer(
    db: &AsyncDaemonDb,
    request: &PolicyTransferDumpRequest,
) -> Result<PolicyTransferBundle, CliError> {
    service::dump_policies(db, request).await
}

pub(crate) async fn import_policy_transfer(
    db: &AsyncDaemonDb,
    request: &PolicyTransferImportRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::import_policies(db, request).await
}

pub(crate) async fn create_policy_scenario(
    db: &AsyncDaemonDb,
    request: &PolicyScenarioCreateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::create_policy_scenario(db, request).await
}

pub(crate) async fn update_policy_scenario(
    db: &AsyncDaemonDb,
    request: &PolicyScenarioUpdateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::update_policy_scenario(db, request).await
}

pub(crate) async fn delete_policy_scenario(
    db: &AsyncDaemonDb,
    request: &PolicyScenarioDeleteRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::delete_policy_scenario(db, request).await
}

pub(crate) async fn reset_policy_scenarios(
    db: &AsyncDaemonDb,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::reset_policy_scenarios(db).await
}
