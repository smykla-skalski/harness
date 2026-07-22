use super::remote_assignment_test_support::{
    HOST, INSTANCE, NOW, PRINCIPAL, accept_executor, detached_offer, executor_fixture,
};
use super::remote_settlement_test_support::unknown_workspace_assignment;
use super::{TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome};
use crate::daemon::db::AsyncDaemonDb;

const SETTLED_AT: &str = "2026-07-19T10:00:40Z";
const CLEANED_AT: &str = "2026-07-19T10:00:50Z";

#[tokio::test]
async fn active_local_executor_fences_identity_replacement_and_capacity() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    let mut replacement = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load local executor settings");
    replacement.local_execution_host.host_id = "executor-b".into();

    let error = fixture
        .db
        .replace_task_board_orchestrator_settings(&replacement)
        .await
        .expect_err("active executor identity replacement must be fenced");
    assert!(error.to_string().contains("active remote assignments"));
    assert_eq!(host_state(&fixture.db, HOST).await, Some(true));
    assert_eq!(host_state(&fixture.db, "executor-b").await, None);
    assert_eq!(
        fixture
            .db
            .task_board_orchestrator_settings()
            .await
            .expect("reload fenced settings")
            .local_execution_host
            .host_id,
        HOST
    );

    let second = distinct_offer();
    let outcome = fixture
        .db
        .accept_task_board_remote_assignment_offer(&second, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("reject over-capacity offer durably");
    assert!(matches!(outcome, TaskBoardRemoteOfferOutcome::Rejected(_)));

    sqlx::query(
        "UPDATE task_board_remote_assignments
         SET state = 'cancelled', completed_at = ?2, updated_at = ?2
         WHERE assignment_id = ?1 AND state = 'offered'",
    )
    .bind(&accepted.assignment_id)
    .bind("2026-07-19T10:00:30Z")
    .execute(fixture.db.pool())
    .await
    .expect("terminalize active executor assignment");

    fixture
        .db
        .replace_task_board_orchestrator_settings(&replacement)
        .await
        .expect("terminal assignment permits executor identity replacement");
    assert_eq!(host_state(&fixture.db, HOST).await, Some(false));
    assert_eq!(host_state(&fixture.db, "executor-b").await, Some(true));
}

#[tokio::test]
async fn cleaned_unknown_allows_host_replacement_and_clear_without_losing_history() {
    let fixture = executor_fixture(1).await;
    let (unknown, settlement) = unknown_workspace_assignment(&fixture).await;
    let mut replacement = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load local executor settings");
    replacement.local_execution_host.host_id = "executor-b".into();
    assert_identity_change_fenced(&fixture.db, &replacement).await;
    let mut cleared = replacement.clone();
    cleared.local_execution_host = Default::default();
    assert_identity_change_fenced(&fixture.db, &cleared).await;

    fixture
        .db
        .settle_task_board_remote_assignment(&settlement, PRINCIPAL, SETTLED_AT)
        .await
        .expect("persist exact unknown settlement");
    let TaskBoardRemoteMutationOutcome::Updated(cleaned) = fixture
        .db
        .complete_task_board_remote_assignment_cleanup(&settlement, PRINCIPAL, CLEANED_AT)
        .await
        .expect("persist exact unknown cleanup")
    else {
        panic!("first exact cleanup did not update assignment");
    };
    assert_eq!(cleaned.assignment_id, unknown.assignment_id);
    fixture
        .db
        .replace_task_board_orchestrator_settings(&replacement)
        .await
        .expect("cleaned unknown permits executor identity replacement");
    assert_eq!(host_state(&fixture.db, HOST).await, Some(false));
    assert_eq!(host_state(&fixture.db, "executor-b").await, Some(true));
    assert_settlement_history(&fixture.db, &unknown.assignment_id).await;

    let database_path = fixture._temp.path().join("executor.db");
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("restart executor database");
    let TaskBoardRemoteMutationOutcome::Replayed(replayed) = restarted
        .complete_task_board_remote_assignment_cleanup(
            &settlement,
            PRINCIPAL,
            "2026-07-19T10:01:00Z",
        )
        .await
        .expect("replay exact cleanup after restart")
    else {
        panic!("cleanup replay after restart mutated twice");
    };
    assert_eq!(replayed.cleanup_completed_at.as_deref(), Some(CLEANED_AT));
    restarted
        .replace_task_board_orchestrator_settings(&cleared)
        .await
        .expect("cleaned unknown permits executor identity clear after restart");
    assert_eq!(host_state(&restarted, "executor-b").await, Some(false));
    assert_settlement_history(&restarted, &unknown.assignment_id).await;
}

async fn assert_identity_change_fenced(
    db: &AsyncDaemonDb,
    settings: &crate::task_board::TaskBoardOrchestratorSettings,
) {
    let error = db
        .replace_task_board_orchestrator_settings(settings)
        .await
        .expect_err("unclean unknown must fence executor identity changes");
    assert!(error.to_string().contains("active remote assignments"));
    assert_eq!(host_state(db, HOST).await, Some(true));
}

async fn assert_settlement_history(db: &AsyncDaemonDb, assignment_id: &str) {
    assert!(
        db.task_board_remote_assignment(assignment_id)
            .await
            .expect("load retained terminal assignment")
            .is_some()
    );
    assert!(
        db.task_board_remote_settlement_receipt(assignment_id)
            .await
            .expect("load retained settlement receipt")
            .is_some()
    );
}

fn distinct_offer() -> crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest {
    let mut request = detached_offer("assignment-executor-2", "attempt-key-2");
    request.binding.execution_id = "execution-detached-2".into();
    request.binding.action_key = "review:reviewer-2".into();
    request.binding.fencing_epoch = 2;
    // The launch must track the rebound binding execution id and action key.
    request.launch = crate::daemon::task_board_remote_transport::wire::test_codex_launch(
        crate::task_board::TaskBoardExecutionPhase::Review,
        "execution-detached-2",
        "review:reviewer-2",
        "Review the frozen revision",
    );
    request.request_sha256.clear();
    request.seal().expect("seal distinct capacity offer")
}

async fn host_state(db: &crate::daemon::db::AsyncDaemonDb, host_id: &str) -> Option<bool> {
    sqlx::query_scalar(
        "SELECT enabled FROM task_board_execution_hosts
         WHERE host_id = ?1 AND host_role = 'executor_self'",
    )
    .bind(host_id)
    .fetch_optional(db.pool())
    .await
    .expect("load local executor identity")
}
