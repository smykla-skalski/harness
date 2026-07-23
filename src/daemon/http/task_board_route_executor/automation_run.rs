use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunOnceResponse,
};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardAutomationRunOutcome, TaskBoardAutomationRunTrigger, TaskBoardAutomationScope,
    TaskBoardOrchestratorSettings, TaskBoardStatus,
};

use super::super::DaemonHttpState;
use super::handle_run_once_result;

pub(super) async fn run_once_durable(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    request: TaskBoardOrchestratorRunOnceRequest,
    trigger: TaskBoardAutomationRunTrigger,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let dry_run = request.dry_run.unwrap_or(settings.dry_run_default);
    let scope = durable_scope(&request, &settings);
    let start = service::TaskBoardAutomationRunSession::acquire(
        db,
        trigger,
        request.actor.clone(),
        dry_run,
        scope,
    )
    .await?;
    let session = admitted_session(start)?;
    let result = Box::pin(execute_durable_run(state, db, &request, &session)).await;
    finish_durable_run(db, session, result).await
}

fn admitted_session(
    start: service::TaskBoardAutomationRunStart,
) -> Result<service::TaskBoardAutomationRunSession, CliError> {
    match start {
        service::TaskBoardAutomationRunStart::Acquired(session) => Ok(*session),
        service::TaskBoardAutomationRunStart::Busy { run_id } => {
            Err(CliErrorKind::session_agent_conflict(format!(
                "task-board automation run '{run_id}' is already active"
            ))
            .into())
        }
        service::TaskBoardAutomationRunStart::Disabled => {
            Err(CliErrorKind::session_agent_conflict("task-board automation is stopping").into())
        }
    }
}

async fn execute_durable_run(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    request: &TaskBoardOrchestratorRunOnceRequest,
    session: &service::TaskBoardAutomationRunSession,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    let result = Box::pin(service::run_task_board_orchestrator_once_with_session_db(
        db, request, session,
    ))
    .await;
    let status = result?;
    session.begin_stage(6, "worker_start", None, None).await?;
    let status = handle_run_once_result(state, Ok(status), db).await;
    match status {
        Ok(status) => {
            session
                .complete_stage(6, "worker_start", None, None)
                .await?;
            Ok(status)
        }
        Err(error) => {
            session.fail_stage(6, "worker_start", &error).await?;
            Err(error)
        }
    }
}

async fn finish_durable_run(
    db: &AsyncDaemonDb,
    session: service::TaskBoardAutomationRunSession,
    result: Result<TaskBoardOrchestratorRunOnceResponse, CliError>,
) -> Result<TaskBoardOrchestratorRunOnceResponse, CliError> {
    match result {
        Ok(status) => {
            let outcome = durable_run_outcome(&status, session.had_sync_failures());
            let actual_outcome = session.finalize(outcome, None).await?;
            ensure_not_cancelled(actual_outcome)?;
            service::task_board_orchestrator_status_db(db).await
        }
        Err(error) => {
            let actual_outcome = session
                .finalize(TaskBoardAutomationRunOutcome::Failed, Some(&error))
                .await?;
            ensure_not_cancelled(actual_outcome)?;
            Err(error)
        }
    }
}

fn durable_run_outcome(
    status: &TaskBoardOrchestratorRunOnceResponse,
    had_sync_failures: bool,
) -> TaskBoardAutomationRunOutcome {
    let has_failures = had_sync_failures
        || status.last_run.as_ref().is_some_and(|run| {
            run.dispatch
                .as_ref()
                .is_some_and(|dispatch| !dispatch.failures.is_empty())
                || run.evaluation.as_ref().is_some_and(|evaluation| {
                    evaluation.failed > 0 || !evaluation.signal_failures.is_empty()
                })
        });
    completed_run_outcome(has_failures, status.last_run_applied_count())
}

fn durable_scope(
    request: &TaskBoardOrchestratorRunOnceRequest,
    settings: &TaskBoardOrchestratorSettings,
) -> TaskBoardAutomationScope {
    let status = request.item_id.is_none().then(|| {
        request
            .status
            .or(settings.dispatch_status_filter)
            .map(TaskBoardStatus::canonical_persisted_status)
    });
    TaskBoardAutomationScope {
        item_id: request.item_id.clone(),
        status: status.flatten(),
        ..TaskBoardAutomationScope::default()
    }
}

fn ensure_not_cancelled(outcome: TaskBoardAutomationRunOutcome) -> Result<(), CliError> {
    if outcome == TaskBoardAutomationRunOutcome::Cancelled {
        return Err(
            CliErrorKind::session_agent_conflict("task-board automation is stopping").into(),
        );
    }
    Ok(())
}

const fn completed_run_outcome(
    has_failures: bool,
    applied_count: usize,
) -> TaskBoardAutomationRunOutcome {
    if has_failures {
        return TaskBoardAutomationRunOutcome::Partial;
    }
    if applied_count == 0 {
        return TaskBoardAutomationRunOutcome::Noop;
    }
    TaskBoardAutomationRunOutcome::Completed
}

#[cfg(test)]
mod tests {
    use sqlx::query_scalar;

    use super::*;
    use crate::task_board::TaskBoardAutomationDesiredMode;

    #[test]
    fn completed_run_outcome_distinguishes_changes_failures_and_noop() {
        assert_eq!(
            completed_run_outcome(false, 0),
            TaskBoardAutomationRunOutcome::Noop
        );
        assert_eq!(
            completed_run_outcome(false, 1),
            TaskBoardAutomationRunOutcome::Completed
        );
        assert_eq!(
            completed_run_outcome(true, 0),
            TaskBoardAutomationRunOutcome::Partial
        );
    }

    #[test]
    fn durable_scope_ignores_status_for_an_explicit_item() {
        let scope = durable_scope(
            &TaskBoardOrchestratorRunOnceRequest {
                item_id: Some("task-neutral".into()),
                status: Some(TaskBoardStatus::New),
                ..TaskBoardOrchestratorRunOnceRequest::default()
            },
            &TaskBoardOrchestratorSettings::default(),
        );

        assert_eq!(scope.item_id.as_deref(), Some("task-neutral"));
        assert_eq!(scope.status, None);
    }

    #[test]
    fn durable_scope_canonicalizes_the_status_filter() {
        let scope = durable_scope(
            &TaskBoardOrchestratorRunOnceRequest {
                status: Some(TaskBoardStatus::New),
                ..TaskBoardOrchestratorRunOnceRequest::default()
            },
            &TaskBoardOrchestratorSettings::default(),
        );

        assert_eq!(scope.status, Some(TaskBoardStatus::Todo));
    }

    #[tokio::test]
    async fn stop_winning_the_finalization_race_surfaces_cancellation() {
        let temp = tempfile::tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("open database");
        db.start_task_board_automation(
            TaskBoardAutomationDesiredMode::Continuous,
            chrono::Utc::now(),
        )
        .await
        .expect("start automation");
        let start = service::TaskBoardAutomationRunSession::acquire(
            &db,
            TaskBoardAutomationRunTrigger::Manual,
            Some("operator".into()),
            false,
            TaskBoardAutomationScope::default(),
        )
        .await
        .expect("acquire session");
        let service::TaskBoardAutomationRunStart::Acquired(session) = start else {
            panic!("manual run should be acquired");
        };
        let run_id = session.run_id().to_owned();
        let status = service::task_board_orchestrator_status_db(&db)
            .await
            .expect("load status");
        db.stop_task_board_automation(chrono::Utc::now())
            .await
            .expect("stop automation");

        let error = finish_durable_run(&db, *session, Ok(status))
            .await
            .expect_err("cancelled finalization must not report success");

        assert_eq!(error.code(), "KSRCLI092");
        let outcome = query_scalar::<_, String>(
            "SELECT outcome FROM task_board_orchestrator_runs WHERE run_id = ?1",
        )
        .bind(run_id)
        .fetch_one(db.pool())
        .await
        .expect("load durable outcome");
        assert_eq!(outcome, "cancelled");
    }
}
