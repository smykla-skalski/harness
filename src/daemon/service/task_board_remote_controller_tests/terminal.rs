use std::future::ready;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use sqlx::query;

use crate::daemon::db::{
    TaskBoardRemoteAssignmentRecord, detached_terminal_assignment, remote_controller_fixture,
    restore_parent_to_targetless_preparing,
};
use crate::errors::CliError;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
};

#[tokio::test]
async fn detached_completed_or_failed_return_before_any_terminal_client_operation() {
    for state in [
        TaskBoardRemoteAssignmentState::Completed,
        TaskBoardRemoteAssignmentState::Failed,
    ] {
        let fixture = remote_controller_fixture(1).await;
        let assignment = detached_terminal_assignment(&fixture, state).await;
        restore_parent_to_targetless_preparing(&fixture).await;
        let sequence = fixture
            .db
            .current_change_sequence()
            .await
            .expect("load preflight sequence");
        let calls = Arc::new(AtomicUsize::new(0));
        let fetch_calls = Arc::clone(&calls);
        let cleanup_calls = Arc::clone(&calls);
        let settle_calls = Arc::clone(&calls);

        let progressed = super::super::terminal::finish_terminal_assignment_with(
            &fixture.db,
            &assignment,
            move || counted_terminal_operation(fetch_calls),
            move |_| counted_terminal_operation(cleanup_calls),
            move |_| counted_terminal_operation(settle_calls),
        )
        .await
        .expect("reject detached result terminal before terminal I/O");

        assert!(!progressed);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(
            fixture
                .db
                .current_change_sequence()
                .await
                .expect("reload rejected sequence"),
            sequence
        );
        assert_eq!(load_assignment(&fixture.db, &assignment).await, assignment);
    }
}

#[tokio::test]
async fn same_target_with_any_mismatched_active_adoption_proof_has_zero_terminal_io() {
    for corruption in [
        ActiveTargetCorruption::Host,
        ActiveTargetCorruption::Epoch,
        ActiveTargetCorruption::Action,
        ActiveTargetCorruption::Attempt,
        ActiveTargetCorruption::Idempotency,
        ActiveTargetCorruption::AttemptState,
    ] {
        let fixture = remote_controller_fixture(1).await;
        let assignment =
            detached_terminal_assignment(&fixture, TaskBoardRemoteAssignmentState::Completed).await;
        corrupt_active_target_proof(&fixture, corruption).await;
        let sequence = fixture
            .db
            .current_change_sequence()
            .await
            .expect("load corrupted target sequence");
        let calls = Arc::new(AtomicUsize::new(0));
        let fetch_calls = Arc::clone(&calls);
        let cleanup_calls = Arc::clone(&calls);
        let settle_calls = Arc::clone(&calls);

        let result = super::super::terminal::finish_terminal_assignment_with(
            &fixture.db,
            &assignment,
            move || counted_terminal_operation(fetch_calls),
            move |_| counted_terminal_operation(cleanup_calls),
            move |_| counted_terminal_operation(settle_calls),
        )
        .await;

        assert!(
            !matches!(result, Ok(true)),
            "{corruption:?} must reject the exact active adoption proof"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0, "{corruption:?}");
        assert_eq!(
            fixture
                .db
                .current_change_sequence()
                .await
                .expect("reload corrupted target sequence"),
            sequence,
            "{corruption:?}"
        );
    }
}

#[tokio::test]
async fn result_adopted_handoff_settles_after_parent_deletion_without_fetch_or_adoption() {
    let fixture = remote_controller_fixture(1).await;
    let assignment =
        detached_terminal_assignment(&fixture, TaskBoardRemoteAssignmentState::Failed).await;
    let parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load result-adoption parent")
        .expect("result-adoption parent exists");
    fixture
        .db
        .adopt_task_board_remote_terminal_result(
            &TaskBoardWorkflowExecutionCas::from(&parent),
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await
        .expect("adopt failed remote result before deletion");
    query("DELETE FROM task_board_workflow_executions WHERE execution_id = ?1")
        .bind(&fixture.execution.execution_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete settled result parent");
    let fetches = Arc::new(AtomicUsize::new(0));
    let cleanups = Arc::new(AtomicUsize::new(0));
    let settlements = Arc::new(AtomicUsize::new(0));
    let fetch_count = Arc::clone(&fetches);
    let cleanup_count = Arc::clone(&cleanups);
    let settlement_count = Arc::clone(&settlements);

    assert!(
        super::super::terminal::finish_terminal_assignment_with(
            &fixture.db,
            &assignment,
            move || counted_terminal_operation(fetch_count),
            move |_| counted_terminal_operation(cleanup_count),
            move |_| counted_terminal_operation(settlement_count),
        )
        .await
        .expect("settle immutable result-adopted handoff after parent deletion")
    );
    assert_eq!(fetches.load(Ordering::SeqCst), 0);
    assert_eq!(cleanups.load(Ordering::SeqCst), 0);
    assert_eq!(settlements.load(Ordering::SeqCst), 1);
}

#[derive(Clone, Copy, Debug)]
enum ActiveTargetCorruption {
    Host,
    Epoch,
    Action,
    Attempt,
    Idempotency,
    AttemptState,
}

async fn corrupt_active_target_proof(
    fixture: &crate::daemon::db::RemoteControllerFixture,
    corruption: ActiveTargetCorruption,
) {
    if matches!(
        corruption,
        ActiveTargetCorruption::Idempotency | ActiveTargetCorruption::AttemptState
    ) {
        corrupt_active_attempt(fixture, corruption).await;
        return;
    }
    let mut parent = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load active target corruption parent")
        .expect("active target corruption parent exists");
    match corruption {
        ActiveTargetCorruption::Host => parent.ownership.host_id = Some("wrong-host".into()),
        ActiveTargetCorruption::Epoch => parent.ownership.fencing_epoch += 1,
        ActiveTargetCorruption::Action => {
            parent.ownership.resources.insert(
                TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE.into(),
                "wrong-action".into(),
            );
        }
        ActiveTargetCorruption::Attempt => {
            parent.ownership.resources.insert(
                TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE.into(),
                "99".into(),
            );
        }
        ActiveTargetCorruption::Idempotency | ActiveTargetCorruption::AttemptState => {
            unreachable!()
        }
    }
    let ownership = serde_json::to_string(&parent.ownership).expect("encode corrupt ownership");
    query(
        "UPDATE task_board_workflow_executions
         SET host_id = ?2, fencing_epoch = ?3, resource_ownership_json = ?4
         WHERE execution_id = ?1",
    )
    .bind(&parent.execution_id)
    .bind(&parent.ownership.host_id)
    .bind(i64::try_from(parent.ownership.fencing_epoch).expect("fencing epoch fits i64"))
    .bind(ownership)
    .execute(fixture.db.pool())
    .await
    .expect("persist explicit active-target corruption");
}

async fn corrupt_active_attempt(
    fixture: &crate::daemon::db::RemoteControllerFixture,
    corruption: ActiveTargetCorruption,
) {
    match corruption {
        ActiveTargetCorruption::Idempotency => {
            query(
                "UPDATE task_board_execution_attempts
                 SET idempotency_key = 'wrong-idempotency'
                 WHERE execution_id = ?1 AND action_key = ?2 AND attempt = ?3",
            )
            .bind(&fixture.attempt.execution_id)
            .bind(&fixture.attempt.action_key)
            .bind(i64::from(fixture.attempt.attempt))
            .execute(fixture.db.pool())
            .await
            .expect("persist explicit idempotency corruption");
        }
        ActiveTargetCorruption::AttemptState => {
            query(
                "UPDATE task_board_execution_attempts
                 SET state = 'preparing'
                 WHERE execution_id = ?1 AND action_key = ?2 AND attempt = ?3",
            )
            .bind(&fixture.attempt.execution_id)
            .bind(&fixture.attempt.action_key)
            .bind(i64::from(fixture.attempt.attempt))
            .execute(fixture.db.pool())
            .await
            .expect("persist explicit attempt-state corruption");
        }
        _ => unreachable!("attempt corruption only"),
    }
}

fn counted_terminal_operation(
    calls: Arc<AtomicUsize>,
) -> impl std::future::Future<Output = Result<(), CliError>> {
    calls.fetch_add(1, Ordering::SeqCst);
    ready(Ok(()))
}

async fn load_assignment(
    db: &crate::daemon::db::AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> TaskBoardRemoteAssignmentRecord {
    db.task_board_remote_assignment(&assignment.assignment_id)
        .await
        .expect("load terminal assignment")
        .expect("terminal assignment exists")
}
