use crate::daemon::protocol::{
    TaskBoardPolicyCanvasCreateRequest, TaskBoardPolicyCanvasDeleteRequest,
    TaskBoardPolicyCanvasDuplicateRequest, TaskBoardPolicyCanvasRenameRequest,
    TaskBoardPolicyCanvasSetActiveRequest, TaskBoardPolicyCanvasWorkspaceResponse,
    TaskBoardPolicyPipelineAuditRequest, TaskBoardPolicyPipelineAuditResponse,
    TaskBoardPolicyPipelineGetRequest, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelinePromoteResponse, TaskBoardPolicyPipelineResponse,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSaveDraftResponse,
    TaskBoardPolicyPipelineSimulateRequest, TaskBoardPolicyPipelineSimulationResponse,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::run_blocking;

pub(crate) async fn policy_canvas_workspace()
-> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    run_blocking(
        "policy canvas workspace",
        service::task_board_policy_canvas_workspace,
    )
    .await
}

pub(crate) async fn create_policy_canvas(
    request: &TaskBoardPolicyCanvasCreateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let request = request.clone();
    run_blocking("policy canvas create", move || {
        service::create_task_board_policy_canvas(&request)
    })
    .await
}

pub(crate) async fn duplicate_policy_canvas(
    request: &TaskBoardPolicyCanvasDuplicateRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let request = request.clone();
    run_blocking("policy canvas duplicate", move || {
        service::duplicate_task_board_policy_canvas(&request)
    })
    .await
}

pub(crate) async fn rename_policy_canvas(
    request: &TaskBoardPolicyCanvasRenameRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let request = request.clone();
    run_blocking("policy canvas rename", move || {
        service::rename_task_board_policy_canvas(&request)
    })
    .await
}

pub(crate) async fn set_active_policy_canvas(
    request: &TaskBoardPolicyCanvasSetActiveRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let request = request.clone();
    run_blocking("policy canvas set active", move || {
        service::set_active_task_board_policy_canvas(&request)
    })
    .await
}

pub(crate) async fn delete_policy_canvas(
    request: &TaskBoardPolicyCanvasDeleteRequest,
) -> Result<TaskBoardPolicyCanvasWorkspaceResponse, CliError> {
    let request = request.clone();
    run_blocking("policy canvas delete", move || {
        service::delete_task_board_policy_canvas(&request)
    })
    .await
}

pub(crate) async fn policy_pipeline(
    request: &TaskBoardPolicyPipelineGetRequest,
) -> Result<TaskBoardPolicyPipelineResponse, CliError> {
    let request = request.clone();
    run_blocking("policy pipeline", move || {
        service::task_board_policy_pipeline(&request)
    })
    .await
}

pub(crate) async fn save_policy_pipeline_draft(
    request: &TaskBoardPolicyPipelineSaveDraftRequest,
) -> Result<TaskBoardPolicyPipelineSaveDraftResponse, CliError> {
    let request = request.clone();
    run_blocking("policy pipeline save draft", move || {
        service::save_task_board_policy_pipeline_draft(&request)
    })
    .await
}

pub(crate) async fn simulate_policy_pipeline(
    request: &TaskBoardPolicyPipelineSimulateRequest,
) -> Result<TaskBoardPolicyPipelineSimulationResponse, CliError> {
    let request = request.clone();
    run_blocking("policy pipeline simulate", move || {
        service::simulate_task_board_policy_pipeline(&request)
    })
    .await
}

pub(crate) async fn promote_policy_pipeline(
    request: &TaskBoardPolicyPipelinePromoteRequest,
) -> Result<TaskBoardPolicyPipelinePromoteResponse, CliError> {
    let request = request.clone();
    run_blocking("policy pipeline promote", move || {
        service::promote_task_board_policy_pipeline(&request)
    })
    .await
}

pub(crate) async fn audit_policy_pipeline(
    request: &TaskBoardPolicyPipelineAuditRequest,
) -> Result<TaskBoardPolicyPipelineAuditResponse, CliError> {
    let request = request.clone();
    run_blocking("policy pipeline audit", move || {
        service::audit_task_board_policy_pipeline(&request)
    })
    .await
}
