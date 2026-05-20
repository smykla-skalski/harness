use crate::daemon::protocol::{
    TaskBoardPolicyPipelineAuditResponse, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelinePromoteResponse, TaskBoardPolicyPipelineResponse,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSaveDraftResponse,
    TaskBoardPolicyPipelineSimulateRequest, TaskBoardPolicyPipelineSimulationResponse,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::run_blocking;

pub(crate) async fn policy_pipeline() -> Result<TaskBoardPolicyPipelineResponse, CliError> {
    run_blocking("policy pipeline", service::task_board_policy_pipeline).await
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

pub(crate) async fn audit_policy_pipeline() -> Result<TaskBoardPolicyPipelineAuditResponse, CliError>
{
    run_blocking(
        "policy pipeline audit",
        service::audit_task_board_policy_pipeline,
    )
    .await
}
