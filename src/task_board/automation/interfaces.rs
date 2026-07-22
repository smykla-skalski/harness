use async_trait::async_trait;

use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAdmissionRequirement, TaskBoardAutomationScope, TaskBoardLifecycleOutcome,
    TaskBoardLifecycleRequest, TaskBoardWorkflowSnapshot,
};

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
