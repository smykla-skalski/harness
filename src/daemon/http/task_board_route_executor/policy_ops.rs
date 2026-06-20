use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
    TaskBoardPolicyCanvasWorkspaceResponse, TaskBoardPolicyExportRequest,
    TaskBoardPolicyExportResponse, TaskBoardPolicyImportRequest, TaskBoardPolicyImportResponse,
    TaskBoardPolicyPipelineAuditRequest, TaskBoardPolicyPipelineAuditResponse,
    TaskBoardPolicyPipelineGetRequest, TaskBoardPolicyPipelineGoLiveDiffRequest,
    TaskBoardPolicyPipelineGoLiveDiffResponse, TaskBoardPolicyPipelineMakeLiveRequest,
    TaskBoardPolicyPipelineMakeLiveResponse, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelinePromoteResponse, TaskBoardPolicyPipelineReplayRequest,
    TaskBoardPolicyPipelineReplayResponse, TaskBoardPolicyPipelineResponse,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSaveDraftResponse,
    TaskBoardPolicyPipelineSimulateRequest, TaskBoardPolicyPipelineSimulationResponse,
    TaskBoardPolicyScenarioCreateRequest, TaskBoardPolicyScenarioDeleteRequest,
    TaskBoardPolicyScenarioUpdateRequest,
};
use crate::daemon::service;
use crate::errors::CliError;

pub(crate) async fn policy_canvas_workspace(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::task_board_policy_canvas_workspace(db).await
}

pub(crate) async fn create_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasCreateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::create_task_board_policy_canvas(db, request).await
}

pub(crate) async fn duplicate_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasDuplicateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::duplicate_task_board_policy_canvas(db, request).await
}

pub(crate) async fn rename_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasRenameRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::rename_task_board_policy_canvas(db, request).await
}

pub(crate) async fn set_active_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasSetActiveRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::set_active_task_board_policy_canvas(db, request).await
}

pub(crate) async fn delete_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasDeleteRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::delete_task_board_policy_canvas(db, request).await
}

pub(crate) async fn set_policy_canvas_global_enforcement(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyCanvasSetGlobalEnforcementRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::set_task_board_policy_canvas_global_enforcement(db, request).await
}

pub(crate) async fn policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineGetRequest,
) -> Result<TaskBoardPolicyPipelineResponse, CliError> {
    service::task_board_policy_pipeline(db, request).await
}

pub(crate) async fn save_policy_pipeline_draft(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineSaveDraftRequest,
) -> Result<TaskBoardPolicyPipelineSaveDraftResponse, CliError> {
    service::save_task_board_policy_pipeline_draft(db, request).await
}

pub(crate) async fn simulate_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineSimulateRequest,
) -> Result<TaskBoardPolicyPipelineSimulationResponse, CliError> {
    service::simulate_task_board_policy_pipeline(db, request).await
}

pub(crate) async fn promote_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelinePromoteRequest,
) -> Result<TaskBoardPolicyPipelinePromoteResponse, CliError> {
    service::promote_task_board_policy_pipeline(db, request).await
}

pub(crate) async fn make_live_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineMakeLiveRequest,
) -> Result<TaskBoardPolicyPipelineMakeLiveResponse, CliError> {
    service::make_live_task_board_policy_pipeline(db, request).await
}

pub(crate) async fn go_live_diff_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineGoLiveDiffRequest,
) -> Result<TaskBoardPolicyPipelineGoLiveDiffResponse, CliError> {
    service::go_live_diff_task_board_policy_pipeline(db, request).await
}

pub(crate) async fn replay_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineReplayRequest,
) -> Result<TaskBoardPolicyPipelineReplayResponse, CliError> {
    service::replay_task_board_policy_pipeline(db, request).await
}

pub(crate) async fn audit_policy_pipeline(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyPipelineAuditRequest,
) -> Result<TaskBoardPolicyPipelineAuditResponse, CliError> {
    service::audit_task_board_policy_pipeline(db, request).await
}

pub(crate) async fn export_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyExportRequest,
) -> Result<TaskBoardPolicyExportResponse, CliError> {
    service::export_task_board_policy(db, request).await
}

pub(crate) async fn import_policy_canvas(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyImportRequest,
) -> Result<TaskBoardPolicyImportResponse, CliError> {
    service::import_task_board_policy(db, request).await
}

pub(crate) async fn create_policy_scenario(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyScenarioCreateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::create_task_board_policy_scenario(db, request).await
}

pub(crate) async fn update_policy_scenario(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyScenarioUpdateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::update_task_board_policy_scenario(db, request).await
}

pub(crate) async fn delete_policy_scenario(
    db: &AsyncDaemonDb,
    request: &TaskBoardPolicyScenarioDeleteRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::delete_task_board_policy_scenario(db, request).await
}

pub(crate) async fn reset_policy_scenarios(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    service::reset_task_board_policy_scenarios(db).await
}
