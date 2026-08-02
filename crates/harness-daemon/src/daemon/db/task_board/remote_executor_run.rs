use crate::daemon::db::task_board::remote_assignment_start_settlement_queries::RemoteAssignmentStartSettlementQueries;
use crate::daemon::db::{
    AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncDaemonDb, CliError, db_error,
};
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use crate::task_board::remote_wire::wire::RemoteOfferRequest;
use sqlx::query_as;

pub(crate) struct TaskBoardRemoteRuntimeProvenance {
    pub(crate) requested_runtime: String,
    pub(crate) actual_runtime: Option<String>,
    pub(crate) requested_model: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteRunStatus {
    Queued,
    Running,
    WaitingApproval,
    Completed,
    Failed,
    Cancelled,
}

impl TaskBoardRemoteRunStatus {
    pub(crate) const fn is_active(self) -> bool {
        matches!(self, Self::Queued | Self::Running | Self::WaitingApproval)
    }
}

#[derive(Debug, Clone)]
pub(crate) struct TaskBoardRemoteExecutorRun {
    pub(crate) runtime: String,
    pub(crate) run_id: String,
    pub(crate) session_id: String,
    pub(crate) task_id: Option<String>,
    pub(crate) board_item_id: Option<String>,
    pub(crate) workflow_execution_id: Option<String>,
    pub(crate) display_name: Option<String>,
    pub(crate) project_dir: String,
    pub(crate) runtime_thread_id: Option<String>,
    pub(crate) mode: CodexRunMode,
    pub(crate) status: TaskBoardRemoteRunStatus,
    pub(crate) prompt: String,
    pub(crate) final_message: Option<String>,
    pub(crate) error: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) model: Option<String>,
    pub(crate) effort: Option<String>,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_remote_executor_run(
        &self,
        offer: &RemoteOfferRequest,
        run_id: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorRun>, CliError> {
        <Self as RemoteAssignmentStartSettlementQueries>::task_board_remote_executor_run(
            self, offer, run_id,
        )
        .await
    }

    pub(crate) async fn task_board_remote_runtime_provenance(
        &self,
        execution_id: &str,
        run_id: &str,
    ) -> Result<Option<TaskBoardRemoteRuntimeProvenance>, CliError> {
        <Self as RemoteAssignmentStartSettlementQueries>::task_board_remote_runtime_provenance(
            self,
            execution_id,
            run_id,
        )
        .await
    }
}

pub(super) async fn task_board_remote_executor_run(
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
    run_id: &str,
) -> Result<Option<TaskBoardRemoteExecutorRun>, CliError> {
    match offer.launch.runtime.as_str() {
        "codex" => db
            .codex_run(run_id)
            .await
            .map(|run| run.map(TaskBoardRemoteExecutorRun::from)),
        "openrouter" => db
            .agent_turn_run(run_id)
            .await?
            .map(|run| TaskBoardRemoteExecutorRun::from_agent_turn(run, offer))
            .transpose(),
        runtime => Err(db_error(format!(
            "unsupported remote executor runtime '{runtime}'"
        ))),
    }
}

pub(super) async fn task_board_remote_runtime_provenance(
    db: &AsyncDaemonDb,
    execution_id: &str,
    run_id: &str,
) -> Result<Option<TaskBoardRemoteRuntimeProvenance>, CliError> {
    // `started_at` reaches the controller only through a validated executor
    // status emitted after durable run adoption. Before that proof lands,
    // the sealed offer supplies requested provenance but actual stays unknown.
    query_as::<_, (String, Option<String>, Option<String>)>(
        "SELECT json_extract(request_json, '$.launch.runtime'),
                CASE WHEN started_at IS NULL THEN NULL
                     ELSE json_extract(request_json, '$.launch.runtime') END,
                json_extract(request_json, '$.launch.model')
         FROM task_board_remote_assignments
         WHERE execution_id = ?1 AND idempotency_key = ?2 AND legacy_migrated = 0
         ORDER BY offered_at DESC, assignment_id DESC
         LIMIT 1",
    )
    .bind(execution_id)
    .bind(run_id)
    .fetch_optional(db.pool())
    .await
    .map(|row| {
        row.map(|(requested_runtime, actual_runtime, requested_model)| {
            TaskBoardRemoteRuntimeProvenance {
                requested_runtime,
                actual_runtime,
                requested_model,
            }
        })
    })
    .map_err(|error| db_error(format!("load remote runtime provenance: {error}")))
}

impl From<CodexRunSnapshot> for TaskBoardRemoteExecutorRun {
    fn from(run: CodexRunSnapshot) -> Self {
        Self {
            runtime: "codex".into(),
            run_id: run.run_id,
            session_id: run.session_id,
            task_id: run.task_id,
            board_item_id: run.board_item_id,
            workflow_execution_id: run.workflow_execution_id,
            display_name: run.display_name,
            project_dir: run.project_dir,
            runtime_thread_id: run.thread_id,
            mode: run.mode,
            status: codex_status(run.status),
            prompt: run.prompt,
            final_message: run.final_message,
            error: run.error,
            created_at: run.created_at,
            updated_at: run.updated_at,
            model: run.model,
            effort: run.effort,
        }
    }
}

impl TaskBoardRemoteExecutorRun {
    fn from_agent_turn(
        run: AgentTurnRunSnapshot,
        offer: &RemoteOfferRequest,
    ) -> Result<Self, CliError> {
        let session_id = run
            .session_id
            .ok_or_else(|| db_error("remote agent turn run has no session id"))?;
        let project_dir = run
            .project_dir
            .ok_or_else(|| db_error("remote agent turn run has no project directory"))?;
        Ok(Self {
            runtime: run.requested_runtime,
            run_id: run.run_id,
            session_id,
            task_id: run.task_id,
            board_item_id: run.board_item_id,
            workflow_execution_id: run.workflow_execution_id,
            display_name: Some(offer.launch.display_name.clone()),
            project_dir,
            runtime_thread_id: run.runtime_turn_id,
            mode: offer.launch.mode,
            status: agent_turn_status(run.status),
            prompt: offer.launch.prompt.clone(),
            final_message: run.report,
            error: run.error,
            created_at: run.created_at,
            updated_at: run.updated_at,
            model: run.requested_model,
            effort: offer.launch.effort.clone(),
        })
    }
}

const fn codex_status(status: CodexRunStatus) -> TaskBoardRemoteRunStatus {
    match status {
        CodexRunStatus::Queued => TaskBoardRemoteRunStatus::Queued,
        CodexRunStatus::Running => TaskBoardRemoteRunStatus::Running,
        CodexRunStatus::WaitingApproval => TaskBoardRemoteRunStatus::WaitingApproval,
        CodexRunStatus::Completed => TaskBoardRemoteRunStatus::Completed,
        CodexRunStatus::Failed => TaskBoardRemoteRunStatus::Failed,
        CodexRunStatus::Cancelled => TaskBoardRemoteRunStatus::Cancelled,
    }
}

const fn agent_turn_status(status: AgentTurnRunStatus) -> TaskBoardRemoteRunStatus {
    match status {
        AgentTurnRunStatus::Queued => TaskBoardRemoteRunStatus::Queued,
        AgentTurnRunStatus::Running => TaskBoardRemoteRunStatus::Running,
        AgentTurnRunStatus::Completed => TaskBoardRemoteRunStatus::Completed,
        AgentTurnRunStatus::Failed => TaskBoardRemoteRunStatus::Failed,
        AgentTurnRunStatus::Cancelled => TaskBoardRemoteRunStatus::Cancelled,
    }
}
