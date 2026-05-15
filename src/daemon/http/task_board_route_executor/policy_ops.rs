use crate::daemon::protocol::{
    TaskBoardPolicyPipelineAuditResponse, TaskBoardPolicyPipelinePromoteRequest,
    TaskBoardPolicyPipelinePromoteResponse, TaskBoardPolicyPipelineResponse,
    TaskBoardPolicyPipelineSaveDraftRequest, TaskBoardPolicyPipelineSaveDraftResponse,
    TaskBoardPolicyPipelineSimulateRequest, TaskBoardPolicyPipelineSimulationResponse,
};
use crate::daemon::service;
use crate::errors::CliError;

pub(crate) fn policy_pipeline() -> Result<TaskBoardPolicyPipelineResponse, CliError> {
    service::task_board_policy_pipeline()
}

pub(crate) fn save_policy_pipeline_draft(
    request: &TaskBoardPolicyPipelineSaveDraftRequest,
) -> Result<TaskBoardPolicyPipelineSaveDraftResponse, CliError> {
    service::save_task_board_policy_pipeline_draft(request)
}

pub(crate) fn simulate_policy_pipeline(
    request: &TaskBoardPolicyPipelineSimulateRequest,
) -> Result<TaskBoardPolicyPipelineSimulationResponse, CliError> {
    service::simulate_task_board_policy_pipeline(request)
}

pub(crate) fn promote_policy_pipeline(
    request: &TaskBoardPolicyPipelinePromoteRequest,
) -> Result<TaskBoardPolicyPipelinePromoteResponse, CliError> {
    service::promote_task_board_policy_pipeline(request)
}

pub(crate) fn audit_policy_pipeline() -> Result<TaskBoardPolicyPipelineAuditResponse, CliError> {
    service::audit_task_board_policy_pipeline()
}
