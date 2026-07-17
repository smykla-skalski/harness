use crate::daemon::db::AsyncDaemonDb;
#[cfg(test)]
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::daemon::protocol::{
    TaskBoardDispatchDeliverRequest, TaskBoardDispatchDeliverResponse,
    TaskBoardDispatchPickResponse, TaskBoardDispatchRequest, TaskBoardDispatchResponse,
    TaskBoardEvaluateRequest, TaskBoardEvaluationResponse, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunOnceResponse,
};
use crate::daemon::service;
use crate::daemon::task_board_managed_agents::rendered_worker_prompt;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags::task_board_automation_v2_enabled_from_env;
#[cfg(test)]
use crate::task_board::DispatchFailureKind;
use crate::task_board::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchFailure, TaskBoardAutomationRunTrigger,
};
use tokio::task::spawn_blocking;

use super::{DaemonHttpState, require_async_db};

mod automation_run;
mod item_ops;
mod orchestrator_ops;
mod policy_ops;
mod worker_start;

pub(crate) use item_ops::*;
pub(crate) use orchestrator_ops::*;
pub(crate) use policy_ops::*;

pub(super) async fn run_blocking<T, F>(operation: &'static str, work: F) -> Result<T, CliError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, CliError> + Send + 'static,
{
    spawn_blocking(work).await.unwrap_or_else(|error| {
        Err(
            CliErrorKind::workflow_io(format!("task-board {operation} worker failed: {error}"))
                .into(),
        )
    })
}

pub(crate) async fn dispatch(
    state: &DaemonHttpState,
    request: TaskBoardDispatchRequest,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let async_db = require_async_db(state, "task board dispatch")?;
    let result = service::dispatch_task_board_async(&request, async_db).await;
    handle_dispatch_result(state, result, async_db).await
}

pub(crate) async fn deliver(
    state: &DaemonHttpState,
    request: &TaskBoardDispatchDeliverRequest,
) -> Result<TaskBoardDispatchDeliverResponse, CliError> {
    let db = require_async_db(state, "task board dispatch deliver")?;
    if request.dry_run {
        let held = db.held_task_board_dispatch(&request.item_id).await?;
        return Ok(TaskBoardDispatchDeliverResponse {
            rendered_prompt: rendered_worker_prompt(&held.applied, &held.intent_id),
            intent_id: held.intent_id,
            applied: held.applied,
            started_agent: None,
        });
    }
    let mut claim = db.claim_held_task_board_dispatch(&request.item_id).await?;
    let prompt = rendered_worker_prompt(&claim.applied, &claim.intent_id);
    let agent = worker_start::start_and_complete_delivered_worker(state, db, &mut claim).await?;
    Ok(TaskBoardDispatchDeliverResponse {
        intent_id: claim.intent_id,
        applied: claim.applied,
        rendered_prompt: prompt,
        started_agent: Some(agent),
    })
}

pub(crate) async fn pick(
    state: &DaemonHttpState,
) -> Result<TaskBoardDispatchPickResponse, CliError> {
    let db = require_async_db(state, "task board dispatch pick")?;
    service::pick_task_board_dispatch_async(db).await
}

pub(crate) async fn evaluate(
    state: &DaemonHttpState,
    request: TaskBoardEvaluateRequest,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    let async_db = require_async_db(state, "task board evaluate")?;
    let result = service::evaluate_task_board_async(&request, async_db).await;
    if result.as_ref().is_ok_and(|response| response.updated > 0) {
        service::broadcast_sessions_updated_async(&state.sender, Some(async_db)).await;
    }
    result
}

pub(crate) async fn run_once(
    state: &DaemonHttpState,
    request: TaskBoardOrchestratorRunOnceRequest,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    Box::pin(run_once_with_trigger(
        state,
        request,
        TaskBoardAutomationRunTrigger::Manual,
    ))
    .await
}

pub(crate) async fn run_once_with_trigger(
    state: &DaemonHttpState,
    request: TaskBoardOrchestratorRunOnceRequest,
    trigger: TaskBoardAutomationRunTrigger,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let async_db = require_async_db(state, "task board orchestrator run once")?;
    if task_board_automation_v2_enabled_from_env() {
        return Box::pin(automation_run::run_once_durable(
            state, async_db, request, trigger,
        ))
        .await;
    }
    let result = service::run_task_board_orchestrator_once_db(async_db, &request).await;
    handle_run_once_result(state, result, async_db).await
}

async fn handle_dispatch_result(
    state: &DaemonHttpState,
    result: Result<TaskBoardDispatchResponse, CliError>,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardDispatchResponse, CliError> {
    let mut response = result?;
    if !response.applied.is_empty() {
        let (applied, failures) =
            worker_start::start_claimed_workers(state, &response.applied, async_db).await;
        response.applied = applied;
        response.failures.extend(failures);
        broadcast_sessions_updated(state, Some(async_db)).await;
    }
    Ok(response)
}

async fn handle_run_once_result(
    state: &DaemonHttpState,
    result: Result<TaskBoardOrchestratorRunOnceResponse, CliError>,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let mut status = result?;
    if status.last_run_applied_count() > 0 {
        let applied: Vec<DispatchAppliedTask> = status
            .last_run
            .as_ref()
            .and_then(|run| run.dispatch.as_ref())
            .map(|dispatch| dispatch.applied.clone())
            .unwrap_or_default();
        let (kept, failures) = worker_start::start_claimed_workers(state, &applied, async_db).await;
        if let Some(dispatch) = status
            .last_run
            .as_mut()
            .and_then(|run| run.dispatch.as_mut())
        {
            amend_dispatch_for_worker_outcomes(dispatch, kept, failures);
            let mut orchestrator_state = async_db.task_board_orchestrator_state().await?;
            orchestrator_state.last_run.clone_from(&status.last_run);
            async_db
                .replace_task_board_orchestrator_state(&orchestrator_state)
                .await?;
        }
        broadcast_sessions_updated(state, Some(async_db)).await;
    }
    Ok(status)
}

fn amend_dispatch_for_worker_outcomes(
    dispatch: &mut DispatchExecutionSummary,
    kept: Vec<DispatchAppliedTask>,
    failures: Vec<DispatchFailure>,
) {
    dispatch.applied = kept;
    dispatch.failures.extend(failures);
}

/// Shared classifier for worker spawn outcomes. Runs `on_failure` for each
/// failed task so callers can choose whether to apply the rollback (production)
/// or skip it (tests).
#[cfg(test)]
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
            read_only_workflow: None,
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
            size: AgentTuiSize { rows: 24, cols: 80 },
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

        let (kept, failures) = classify_worker_outcomes(&applied, outcomes, |task, error| {
            rollback_calls.push((task.board_item_id.clone(), error.to_string()));
        });

        let kept_ids: Vec<&str> = kept
            .iter()
            .map(|task| task.board_item_id.as_str())
            .collect();
        assert_eq!(kept_ids, vec!["ok-1", "ok-3"]);
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].board_item_id, "fail-2");
        assert_eq!(failures[0].kind, DispatchFailureKind::WorkerSpawnFailed);
        assert!(failures[0].message.contains("worker spawn failed"));
        assert_eq!(rollback_calls.len(), 1);
        assert_eq!(rollback_calls[0].0, "fail-2");
        assert!(rollback_calls[0].1.contains("worker spawn failed"));
    }

    #[test]
    fn startup_failures_amend_orchestrator_dispatch() {
        let original = applied_task("failed");
        let kept = applied_task("kept");
        let failure = DispatchFailure {
            board_item_id: original.board_item_id.clone(),
            kind: DispatchFailureKind::WorkerSpawnFailed,
            message: "spawn failed".into(),
        };
        let mut dispatch = crate::task_board::DispatchExecutionSummary {
            plans: Vec::new(),
            applied: vec![original],
            failures: Vec::new(),
        };

        amend_dispatch_for_worker_outcomes(&mut dispatch, vec![kept], vec![failure]);

        assert_eq!(dispatch.applied[0].board_item_id, "kept");
        assert_eq!(dispatch.failures.len(), 1);
    }
}
