use crate::daemon::protocol::{
    PolicyApprovalGrantResolveRequest, PolicyApprovalGrantResolveResponse,
    PolicyApprovalGrantRevokeRequest, PolicyApprovalGrantRevokeResponse,
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
use harness_kernel::errors::CliError;

use super::super::{DaemonHttpState, require_async_db};
use crate::daemon::db_handle::AsyncDaemonDbHandle;

pub(crate) async fn policy_canvas_workspace(
    db: &AsyncDaemonDbHandle,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::policy_canvas_workspace(db).await
}

pub(crate) async fn create_policy_canvas(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasCreateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::create_policy_canvas(db, request).await
}

pub(crate) async fn duplicate_policy_canvas(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasDuplicateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::duplicate_policy_canvas(db, request).await
}

pub(crate) async fn rename_policy_canvas(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasRenameRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::rename_policy_canvas(db, request).await
}

pub(crate) async fn set_active_policy_canvas(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasSetActiveRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::set_active_policy_canvas(db, request).await
}

pub(crate) async fn delete_policy_canvas(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasDeleteRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::delete_policy_canvas(db, request).await
}

pub(crate) async fn set_policy_canvas_global_enforcement(
    state: &DaemonHttpState,
    request: &PolicyCanvasSetGlobalEnforcementRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    let db = require_async_db(state, "policy canvas global enforcement")?;
    let workspace = service::set_policy_canvas_global_enforcement(db, request).await?;
    if !request.enabled {
        crate::daemon::automation_kill_switch::enforce_policy_automation_control(db).await?;
    }
    Ok(workspace)
}

pub(crate) async fn set_policy_canvas_spawn_requires_live_policy(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasSetSpawnRequiresLivePolicyRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::set_policy_canvas_spawn_requires_live_policy(db, request).await
}

pub(crate) async fn set_policy_canvas_spawn_kill_switch(
    state: &DaemonHttpState,
    request: &PolicyCanvasSetSpawnKillSwitchRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    let db = require_async_db(state, "policy canvas automation kill switch")?;
    let workspace = service::set_policy_canvas_spawn_kill_switch(db, request).await?;
    if request.enabled {
        crate::daemon::automation_kill_switch::enforce_automation_kill_switch(state, db).await?;
    }
    Ok(workspace)
}

pub(crate) async fn list_policy_approval_grants(
    db: &AsyncDaemonDbHandle,
) -> Result<PolicyApprovalGrantsListResponse, CliError> {
    service::list_policy_approval_grants(db).await
}

pub(crate) async fn resolve_policy_approval_grant(
    db: &AsyncDaemonDbHandle,
    request: &PolicyApprovalGrantResolveRequest,
) -> Result<PolicyApprovalGrantResolveResponse, CliError> {
    service::resolve_policy_approval_grant(db, request).await
}

pub(crate) async fn revoke_policy_approval_grant(
    db: &AsyncDaemonDbHandle,
    request: &PolicyApprovalGrantRevokeRequest,
) -> Result<PolicyApprovalGrantRevokeResponse, CliError> {
    service::revoke_policy_approval_grant(db, request).await
}

pub(crate) async fn policy_pipeline(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelineGetRequest,
) -> Result<PolicyPipelineResponse, CliError> {
    service::policy_pipeline(db, request).await
}

pub(crate) async fn save_policy_pipeline_draft(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelineSaveDraftRequest,
) -> Result<PolicyPipelineSaveDraftResponse, CliError> {
    service::save_policy_pipeline_draft(db, request).await
}

pub(crate) async fn simulate_policy_pipeline(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelineSimulateRequest,
) -> Result<PolicyPipelineSimulationResponse, CliError> {
    service::simulate_policy_pipeline(db, request).await
}

pub(crate) async fn promote_policy_pipeline(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelinePromoteRequest,
) -> Result<PolicyPipelinePromoteResponse, CliError> {
    service::promote_policy_pipeline(db, request).await
}

pub(crate) async fn make_live_policy_pipeline(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelineMakeLiveRequest,
) -> Result<PolicyPipelineMakeLiveResponse, CliError> {
    service::make_live_policy_pipeline(db, request).await
}

pub(crate) async fn go_live_diff_policy_pipeline(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelineGoLiveDiffRequest,
) -> Result<PolicyPipelineGoLiveDiffResponse, CliError> {
    service::go_live_diff_policy_pipeline(db, request).await
}

pub(crate) async fn replay_policy_pipeline(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelineReplayRequest,
) -> Result<PolicyPipelineReplayResponse, CliError> {
    service::replay_policy_pipeline(db, request).await
}

pub(crate) async fn audit_policy_pipeline(
    db: &AsyncDaemonDbHandle,
    request: &PolicyPipelineAuditRequest,
) -> Result<PolicyPipelineAuditResponse, CliError> {
    service::audit_policy_pipeline(db, request).await
}

pub(crate) async fn export_policy_canvas(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasExportRequest,
) -> Result<PolicyCanvasExportResponse, CliError> {
    service::export_policy(db, request).await
}

pub(crate) async fn import_policy_canvas(
    db: &AsyncDaemonDbHandle,
    request: &PolicyCanvasImportRequest,
) -> Result<PolicyCanvasImportResponse, CliError> {
    service::import_policy(db, request).await
}

pub(crate) async fn dump_policy_transfer(
    db: &AsyncDaemonDbHandle,
    request: &PolicyTransferDumpRequest,
) -> Result<PolicyTransferBundle, CliError> {
    service::dump_policies(db, request).await
}

pub(crate) async fn import_policy_transfer(
    db: &AsyncDaemonDbHandle,
    request: &PolicyTransferImportRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::import_policies(db, request).await
}

pub(crate) async fn create_policy_scenario(
    db: &AsyncDaemonDbHandle,
    request: &PolicyScenarioCreateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::create_policy_scenario(db, request).await
}

pub(crate) async fn update_policy_scenario(
    db: &AsyncDaemonDbHandle,
    request: &PolicyScenarioUpdateRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::update_policy_scenario(db, request).await
}

pub(crate) async fn delete_policy_scenario(
    db: &AsyncDaemonDbHandle,
    request: &PolicyScenarioDeleteRequest,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::delete_policy_scenario(db, request).await
}

pub(crate) async fn reset_policy_scenarios(
    db: &AsyncDaemonDbHandle,
) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
    service::reset_policy_scenarios(db).await
}
