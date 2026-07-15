use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAdmissionRequirement, TaskBoardAutomationScope, TaskBoardExecutionHostAdvertisement,
    TaskBoardLifecycleOutcome, TaskBoardLifecycleRequest, TaskBoardRemoteExecutionClaim,
    TaskBoardRemoteExecutionRequest, TaskBoardRemoteExecutionResult,
    TaskBoardRemoteExecutionStatus, TaskBoardWorkflowSnapshot,
};

#[async_trait]
pub trait TaskBoardExecutionTargetResolver: Send + Sync {
    async fn resolve_host(
        &self,
        repository: &str,
        workflow: &TaskBoardWorkflowSnapshot,
    ) -> Result<TaskBoardExecutionHostAdvertisement, CliError>;
}

#[async_trait]
pub trait TaskBoardRemoteExecutionClient: Send + Sync {
    async fn claim(
        &self,
        host: &TaskBoardExecutionHostAdvertisement,
        request: &TaskBoardRemoteExecutionRequest,
    ) -> Result<TaskBoardRemoteExecutionClaim, CliError>;

    async fn status(
        &self,
        host: &TaskBoardExecutionHostAdvertisement,
        assignment_id: &str,
    ) -> Result<TaskBoardRemoteExecutionStatus, CliError>;

    async fn result(
        &self,
        host: &TaskBoardExecutionHostAdvertisement,
        assignment_id: &str,
    ) -> Result<TaskBoardRemoteExecutionResult, CliError>;

    async fn cancel(
        &self,
        host: &TaskBoardExecutionHostAdvertisement,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<TaskBoardRemoteExecutionStatus, CliError>;
}

#[async_trait]
pub trait TaskBoardAdmissionRequirementEvaluator: Send + Sync {
    async fn requirements(
        &self,
        workflow: &TaskBoardWorkflowSnapshot,
    ) -> Result<Vec<TaskBoardAdmissionRequirement>, CliError>;
}

#[async_trait]
pub trait TaskBoardLifecycleExecutor: Send + Sync {
    async fn execute(
        &self,
        request: &TaskBoardLifecycleRequest,
    ) -> Result<TaskBoardLifecycleOutcome, CliError>;
}

#[async_trait]
pub trait TaskBoardAutomationAuditSink: Send + Sync {
    async fn record(
        &self,
        event_type: &str,
        run_id: &str,
        scope: &TaskBoardAutomationScope,
        payload: &serde_json::Value,
    ) -> Result<(), CliError>;
}
