use tokio::task::spawn_blocking;
use tracing::warn;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    ManagedAgentSnapshot, TaskBoardDispatchRequest, TaskBoardDispatchResponse,
    TaskBoardEvaluateRequest, TaskBoardEvaluationResponse, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse,
};
use crate::daemon::service;
use crate::daemon::task_board_managed_agents::{
    start_workers_for_applied_dispatch, start_workers_for_run_once_status,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{DispatchAppliedTask, DispatchFailure, DispatchFailureKind};

use super::DaemonHttpState;

mod item_ops;
mod orchestrator_ops;
mod policy_ops;

pub(crate) use item_ops::*;
pub(crate) use orchestrator_ops::*;
pub(crate) use policy_ops::*;

pub(crate) async fn dispatch(
    state: &DaemonHttpState,
    request: TaskBoardDispatchRequest,
) -> Result<TaskBoardDispatchResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result = service::dispatch_task_board_async(&request, async_db.as_ref()).await;
        return handle_dispatch_result(state, result, Some(async_db.as_ref())).await;
    }

    let result = {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::dispatch_task_board(&request, db_ref)
    };
    handle_dispatch_result(state, result, None).await
}

pub(crate) async fn evaluate(
    state: &DaemonHttpState,
    request: TaskBoardEvaluateRequest,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result = service::evaluate_task_board_async(&request, async_db.as_ref()).await;
        if result.as_ref().is_ok_and(|response| response.updated > 0) {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        return result;
    }

    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let result = service::evaluate_task_board(&request, db_ref);
    if result.as_ref().is_ok_and(|response| response.updated > 0) {
        service::broadcast_sessions_updated(&state.sender, db_ref);
    }
    result
}

pub(crate) async fn run_once(
    state: &DaemonHttpState,
    request: TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    if let Some(async_db) = state.async_db.get() {
        let result =
            service::run_task_board_orchestrator_once_async(&request, async_db.as_ref()).await;
        return handle_run_once_result(state, result, Some(async_db.as_ref())).await;
    }

    let db = state.db.get().cloned();
    let result = spawn_blocking(move || {
        let db_guard = db.as_ref().map(|db| db.lock().expect("db lock"));
        let db_ref = db_guard.as_deref();
        service::run_task_board_orchestrator_once(&request, db_ref)
    })
    .await
    .unwrap_or_else(|error| {
        Err(
            CliErrorKind::workflow_io(format!("run task-board orchestrator fallback: {error}"))
                .into(),
        )
    });
    handle_run_once_result(state, result, None).await
}

async fn handle_dispatch_result(
    state: &DaemonHttpState,
    result: Result<TaskBoardDispatchResponse, CliError>,
    async_db: Option<&AsyncDaemonDb>,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let mut response = result?;
    if !response.applied.is_empty() {
        let outcomes = start_workers_for_applied_dispatch(state, &response.applied).await;
        let (applied, failures) = partition_worker_outcomes(&response.applied, outcomes);
        response.applied = applied;
        response.failures.extend(failures);
        broadcast_sessions_updated(state, async_db).await;
    }
    Ok(response)
}

async fn handle_run_once_result(
    state: &DaemonHttpState,
    result: Result<TaskBoardOrchestratorRunOnceResponse, CliError>,
    async_db: Option<&AsyncDaemonDb>,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let status = result?;
    if status.last_run_applied_count() > 0 {
        let outcomes = start_workers_for_run_once_status(state, &status).await;
        // Best-effort rollback for any worker that failed to start. The
        // orchestrator status snapshot is read-only here so we cannot mutate the
        // embedded `applied` list, but the board state has been compensated.
        let applied: Vec<DispatchAppliedTask> = status
            .last_run
            .as_ref()
            .and_then(|run| run.dispatch.as_ref())
            .map(|dispatch| dispatch.applied.clone())
            .unwrap_or_default();
        compensate_failed_workers(&applied, outcomes);
        broadcast_sessions_updated(state, async_db).await;
    }
    Ok(status)
}

fn partition_worker_outcomes(
    applied: &[DispatchAppliedTask],
    outcomes: Vec<Result<ManagedAgentSnapshot, CliError>>,
) -> (Vec<DispatchAppliedTask>, Vec<DispatchFailure>) {
    classify_worker_outcomes(applied, outcomes, |task, error| {
        rollback_dispatched_link(&task.board_item_id, &error.to_string());
    })
}

fn compensate_failed_workers(
    applied: &[DispatchAppliedTask],
    outcomes: Vec<Result<ManagedAgentSnapshot, CliError>>,
) {
    let _ = partition_worker_outcomes(applied, outcomes);
}

/// Shared classifier for worker spawn outcomes. Runs `on_failure` for each
/// failed task so callers can choose whether to apply the rollback (production)
/// or skip it (tests).
fn classify_worker_outcomes(
    applied: &[DispatchAppliedTask],
    outcomes: Vec<Result<ManagedAgentSnapshot, CliError>>,
    mut on_failure: impl FnMut(&DispatchAppliedTask, &CliError),
) -> (Vec<DispatchAppliedTask>, Vec<DispatchFailure>) {
    let mut kept = Vec::new();
    let mut failures = Vec::new();
    for (task, outcome) in applied.iter().zip(outcomes) {
        match outcome {
            Ok(_) => kept.push(task.clone()),
            Err(error) => {
                on_failure(task, &error);
                failures.push(DispatchFailure {
                    board_item_id: task.board_item_id.clone(),
                    kind: DispatchFailureKind::WorkerSpawnFailed,
                    message: error.to_string(),
                });
            }
        }
    }
    (kept, failures)
}

fn rollback_dispatched_link(board_item_id: &str, reason: &str) {
    let undo = service::unlink_dispatched_task_board_item(board_item_id, reason);
    log_rollback_outcome(board_item_id, undo.err());
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_rollback_outcome(board_item_id: &str, undo_error: Option<CliError>) {
    if let Some(error) = undo_error {
        warn!(
            board_item_id,
            error = %error,
            "failed to roll back dispatched task-board item after worker spawn failure",
        );
    }
}

async fn broadcast_sessions_updated(state: &DaemonHttpState, async_db: Option<&AsyncDaemonDb>) {
    if let Some(async_db) = async_db {
        service::broadcast_sessions_updated_async(&state.sender, Some(async_db)).await;
        return;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    service::broadcast_sessions_updated(&state.sender, db_ref);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::agent_tui::{
        AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
    };
    use crate::task_board::dispatch::{
        DispatchLifecycle, EvaluatorIntent, FollowUpPhase, ReviewerIntent, WorkerIntent,
    };
    use crate::task_board::{AgentMode, TaskBoardItem, TaskBoardStatus};

    fn applied_task(id: &str) -> DispatchAppliedTask {
        let mut item = TaskBoardItem::new(
            id.into(),
            id.into(),
            String::new(),
            "2026-05-15T00:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InProgress;
        let lifecycle = DispatchLifecycle::planned(
            &WorkerIntent {
                mode: AgentMode::Headless,
            },
            &ReviewerIntent {
                phase: FollowUpPhase::AfterWorkerReview,
                suggested_persona: "code-reviewer".into(),
                required_consensus: 2,
            },
            &EvaluatorIntent {
                phase: FollowUpPhase::AfterWorkerReview,
                mode: AgentMode::Evaluate,
            },
        );
        DispatchAppliedTask {
            board_item_id: id.into(),
            session_id: format!("session-{id}"),
            work_item_id: format!("work-{id}"),
            lifecycle,
            item,
        }
    }

    fn ok_snapshot(id: &str) -> ManagedAgentSnapshot {
        ManagedAgentSnapshot::Terminal(AgentTuiSnapshot {
            tui_id: id.into(),
            session_id: format!("session-{id}"),
            agent_id: format!("agent-{id}"),
            runtime: "codex".into(),
            status: AgentTuiStatus::Running,
            argv: Vec::new(),
            project_dir: "/tmp".into(),
            size: AgentTuiSize {
                rows: 24,
                cols: 80,
            },
            screen: TerminalScreenSnapshot {
                rows: 24,
                cols: 80,
                cursor_row: 0,
                cursor_col: 0,
                text: String::new(),
            },
            transcript_path: String::new(),
            exit_code: None,
            signal: None,
            error: None,
            created_at: "2026-05-15T00:00:00Z".into(),
            updated_at: "2026-05-15T00:00:00Z".into(),
        })
    }

    #[test]
    fn classify_worker_outcomes_keeps_successes_and_collects_failures() {
        let applied = vec![
            applied_task("ok-1"),
            applied_task("fail-2"),
            applied_task("ok-3"),
        ];
        let outcomes = vec![
            Ok(ok_snapshot("ok-1")),
            Err(CliErrorKind::workflow_io("worker spawn failed").into()),
            Ok(ok_snapshot("ok-3")),
        ];
        let mut rollback_calls = Vec::new();

        let (kept, failures) =
            classify_worker_outcomes(&applied, outcomes, |task, error| {
                rollback_calls.push((task.board_item_id.clone(), error.to_string()));
            });

        let kept_ids: Vec<&str> = kept.iter().map(|task| task.board_item_id.as_str()).collect();
        assert_eq!(kept_ids, vec!["ok-1", "ok-3"]);
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].board_item_id, "fail-2");
        assert_eq!(failures[0].kind, DispatchFailureKind::WorkerSpawnFailed);
        assert!(failures[0].message.contains("worker spawn failed"));
        assert_eq!(rollback_calls.len(), 1);
        assert_eq!(rollback_calls[0].0, "fail-2");
        assert!(rollback_calls[0].1.contains("worker spawn failed"));
    }
}
