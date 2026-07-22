use std::collections::BTreeSet;

use sqlx::{query, query_as, query_scalar};

use super::workflow_executions::{create_execution, execution_ids, set_state, workflow_database};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardExecutionState, TaskBoardWorkflowExecutionRecord};

const EARLY: &str = "2026-07-17T09:00:00Z";
const MIDDLE: &str = "2026-07-17T09:30:00Z";
const LATE: &str = "2026-07-17T10:00:00Z";

#[tokio::test]
async fn recovery_cursor_survives_reopen_and_wraps() {
    let (db, temp) = workflow_database().await;
    running_execution(&db, "a", EARLY).await;
    running_execution(&db, "b", LATE).await;

    assert_eq!(
        execution_ids::<1>(
            &db.recoverable_task_board_workflow_executions(1)
                .await
                .expect("select first recovery page")
        ),
        ["execution-a"]
    );
    let path = temp.path().join("harness.db");
    drop(db);
    let reopened = AsyncDaemonDb::connect(&path)
        .await
        .expect("reopen database");
    assert_eq!(
        execution_ids::<1>(
            &reopened
                .recoverable_task_board_workflow_executions(1)
                .await
                .expect("select second recovery page")
        ),
        ["execution-b"]
    );
    assert_eq!(
        execution_ids::<1>(
            &reopened
                .recoverable_task_board_workflow_executions(1)
                .await
                .expect("wrap recovery page")
        ),
        ["execution-a"]
    );
}

#[tokio::test]
async fn zero_and_exact_limit_do_not_create_or_mutate_cursor_or_semantic_state() {
    let (db, _temp) = workflow_database().await;
    let first = running_execution(&db, "a", EARLY).await;
    let second = running_execution(&db, "b", LATE).await;
    let sequence = db.current_change_sequence().await.expect("change sequence");

    assert!(
        db.recoverable_task_board_workflow_executions(0)
            .await
            .expect("zero recovery limit")
            .is_empty()
    );
    assert_eq!(
        execution_ids::<2>(
            &db.recoverable_task_board_workflow_executions(2)
                .await
                .expect("select exact recovery page")
        ),
        ["execution-a", "execution-b"]
    );

    assert_eq!(recovery_cursor(&db).await, None);
    store_cursor(&db, MIDDLE, "execution-existing").await;
    assert_eq!(
        execution_ids::<2>(
            &db.recoverable_task_board_workflow_executions(2)
                .await
                .expect("repeat exact recovery page")
        ),
        ["execution-a", "execution-b"]
    );
    assert_eq!(
        recovery_cursor(&db).await,
        Some((MIDDLE.into(), "execution-existing".into()))
    );
    assert_eq!(
        db.task_board_workflow_execution(&first.execution_id)
            .await
            .expect("reload first execution"),
        Some(first)
    );
    assert_eq!(
        db.task_board_workflow_execution(&second.execution_id)
            .await
            .expect("reload second execution"),
        Some(second)
    );
    assert_eq!(
        db.current_change_sequence().await.expect("change sequence"),
        sequence
    );
}

#[tokio::test]
async fn recovery_cursor_partially_wraps_across_tied_timestamps() {
    let (db, _temp) = workflow_database().await;
    running_execution(&db, "a", EARLY).await;
    running_execution(&db, "b", MIDDLE).await;
    let cursor = running_execution(&db, "c", LATE).await;
    running_execution(&db, "d", LATE).await;
    store_cursor(&db, &cursor.updated_at, &cursor.execution_id).await;

    let page = db
        .recoverable_task_board_workflow_executions(3)
        .await
        .expect("select partially wrapped recovery page");

    assert_eq!(
        execution_ids::<3>(&page),
        ["execution-d", "execution-a", "execution-b"]
    );
    assert_eq!(
        recovery_cursor(&db).await,
        Some((MIDDLE.into(), "execution-b".into()))
    );
}

#[tokio::test]
async fn vanished_cursor_target_wraps_from_queue_start() {
    let (db, _temp) = workflow_database().await;
    running_execution(&db, "a", EARLY).await;
    running_execution(&db, "b", MIDDLE).await;
    let vanished = running_execution(&db, "c", LATE).await;
    store_cursor(&db, &vanished.updated_at, &vanished.execution_id).await;
    query("DELETE FROM task_board_workflow_executions WHERE execution_id = ?1")
        .bind(&vanished.execution_id)
        .execute(db.pool())
        .await
        .expect("remove cursor target");

    let page = db
        .recoverable_task_board_workflow_executions(1)
        .await
        .expect("select after vanished cursor target");

    assert_eq!(execution_ids::<1>(&page), ["execution-a"]);
    assert_eq!(
        recovery_cursor(&db).await,
        Some((EARLY.into(), "execution-a".into()))
    );
}

#[tokio::test]
async fn concurrent_recovery_selectors_advance_successive_windows() {
    let (db, temp) = workflow_database().await;
    running_execution(&db, "a", EARLY).await;
    running_execution(&db, "b", LATE).await;
    let other = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open concurrent selector");

    let (first, second) = tokio::join!(
        db.recoverable_task_board_workflow_executions(1),
        other.recoverable_task_board_workflow_executions(1)
    );
    let selected = first
        .expect("first selector")
        .into_iter()
        .chain(second.expect("second selector"))
        .map(|execution| execution.execution_id)
        .collect::<BTreeSet<_>>();

    assert_eq!(
        selected,
        BTreeSet::from(["execution-a".to_string(), "execution-b".to_string()])
    );
}

#[tokio::test]
async fn remote_candidates_and_local_recovery_use_independent_restart_safe_cursors() {
    const PAGE: usize = 16;
    let (db, temp) = workflow_database().await;
    for index in 0..48 {
        let state = match index {
            0..=19 => TaskBoardExecutionState::Running,
            20..=27 => TaskBoardExecutionState::Starting,
            _ => TaskBoardExecutionState::Preparing,
        };
        mixed_execution(&db, index, state).await;
    }

    let first_remote = db
        .remote_candidate_task_board_workflow_executions(PAGE)
        .await
        .expect("select first remote-candidate page");
    assert_eq!(first_remote.len(), PAGE);
    assert_eq!(owned_execution_ids(&first_remote), mixed_ids(28..44));
    assert_eq!(recovery_cursor(&db).await, None);
    assert!(remote_candidate_cursor(&db).await.is_some());

    let path = temp.path().join("harness.db");
    drop(db);
    let reopened = AsyncDaemonDb::connect(&path)
        .await
        .expect("reopen database after remote selection");
    let second_remote = reopened
        .remote_candidate_task_board_workflow_executions(PAGE)
        .await
        .expect("resume remote-candidate cursor");
    assert_eq!(second_remote.len(), PAGE);
    let selected_remote = first_remote
        .iter()
        .chain(&second_remote)
        .map(|execution| execution.execution_id.clone())
        .collect::<BTreeSet<_>>();
    assert_eq!(selected_remote, mixed_ids(28..48).into_iter().collect());

    let remote_cursor_before_local = remote_candidate_cursor(&reopened).await;
    let first_local = reopened
        .recoverable_task_board_workflow_executions(PAGE)
        .await
        .expect("select first local recovery page after remote pages");
    assert_eq!(first_local.len(), PAGE);
    assert_eq!(owned_execution_ids(&first_local), mixed_ids(0..16));
    assert_eq!(
        remote_candidate_cursor(&reopened).await,
        remote_cursor_before_local
    );

    drop(reopened);
    let restarted = AsyncDaemonDb::connect(&path)
        .await
        .expect("restart with both durable cursors");
    let second_local = restarted
        .recoverable_task_board_workflow_executions(PAGE)
        .await
        .expect("resume second local recovery page");
    let third_remote = restarted
        .remote_candidate_task_board_workflow_executions(PAGE)
        .await
        .expect("advance remote candidates between local pages");
    let third_local = restarted
        .recoverable_task_board_workflow_executions(PAGE)
        .await
        .expect("resume third local recovery page");
    assert_eq!(second_local.len(), PAGE);
    assert_eq!(third_remote.len(), PAGE);
    assert_eq!(third_local.len(), PAGE);
    assert_eq!(owned_execution_ids(&second_local), mixed_ids(16..32));
    assert_eq!(owned_execution_ids(&third_local), mixed_ids(32..48));
}

#[tokio::test]
async fn malformed_candidate_rolls_back_cursor() {
    let (db, _temp) = workflow_database().await;
    running_execution(&db, "a", EARLY).await;
    running_execution(&db, "b", LATE).await;
    db.recoverable_task_board_workflow_executions(1)
        .await
        .expect("select first recovery page");
    let cursor_before = recovery_cursor(&db).await;
    let sequence = db.current_change_sequence().await.expect("change sequence");
    let snapshot: String = query_scalar(
        "SELECT snapshot_json FROM task_board_workflow_executions
         WHERE execution_id = 'execution-b'",
    )
    .fetch_one(db.pool())
    .await
    .expect("load valid snapshot");
    query(
        "UPDATE task_board_workflow_executions SET snapshot_json = '{}'
         WHERE execution_id = 'execution-b'",
    )
    .execute(db.pool())
    .await
    .expect("corrupt recovery candidate");

    let error = db
        .recoverable_task_board_workflow_executions(1)
        .await
        .expect_err("malformed candidate must fail selection");

    assert!(error.to_string().contains("workflow snapshot"));
    assert_eq!(recovery_cursor(&db).await, cursor_before);
    assert_eq!(
        db.current_change_sequence().await.expect("change sequence"),
        sequence
    );
    query(
        "UPDATE task_board_workflow_executions SET snapshot_json = ?1
         WHERE execution_id = 'execution-b'",
    )
    .bind(snapshot)
    .execute(db.pool())
    .await
    .expect("repair recovery candidate");
    let recovered = db
        .recoverable_task_board_workflow_executions(1)
        .await
        .expect("retry repaired recovery candidate");
    assert_eq!(execution_ids::<1>(&recovered), ["execution-b"]);
}

#[tokio::test]
async fn malformed_candidate_attempt_rolls_back_cursor() {
    let (db, _temp) = workflow_database().await;
    running_execution(&db, "a", EARLY).await;
    running_execution(&db, "b", LATE).await;
    db.recoverable_task_board_workflow_executions(1)
        .await
        .expect("select first recovery page");
    let cursor_before = recovery_cursor(&db).await;
    query(
        "INSERT INTO task_board_execution_attempts (
             execution_id, action_key, attempt, idempotency_key, state,
             started_at, updated_at
         ) VALUES (
             'execution-b', 'review:reviewer', 1, 'malformed-attempt', 'unknown',
             '2026-07-17T10:00:00Z', '2026-07-17T10:00:00Z'
         )",
    )
    .execute(db.pool())
    .await
    .expect("seed malformed recovery attempt");

    let error = db
        .recoverable_task_board_workflow_executions(1)
        .await
        .expect_err("malformed attempt must fail selection");

    assert!(
        error
            .to_string()
            .contains("validate durable execution attempt"),
        "unexpected malformed-attempt error: {error}"
    );
    assert_eq!(recovery_cursor(&db).await, cursor_before);
}

#[tokio::test]
async fn selection_preserves_timestamps_and_later_execution_cas() {
    let (db, _temp) = workflow_database().await;
    let first = running_execution(&db, "a", "2026-07-17T09:30:00.123456789Z").await;
    let second = running_execution(&db, "b", "2099-07-17T09:30:00.987654321Z").await;
    let sequence = db.current_change_sequence().await.expect("change sequence");

    let page = db
        .recoverable_task_board_workflow_executions(1)
        .await
        .expect("select timestamped recovery page");

    assert_eq!(execution_ids::<1>(&page), ["execution-a"]);
    assert_eq!(
        db.task_board_workflow_execution(&first.execution_id)
            .await
            .expect("reload first execution"),
        Some(first.clone())
    );
    assert_eq!(
        db.task_board_workflow_execution(&second.execution_id)
            .await
            .expect("reload second execution"),
        Some(second)
    );
    assert_eq!(
        db.current_change_sequence().await.expect("change sequence"),
        sequence
    );
    let updated = set_state(&db, first, TaskBoardExecutionState::Running, None, LATE).await;
    assert_eq!(updated.updated_at, LATE);
}

async fn running_execution(
    db: &AsyncDaemonDb,
    item_id: &str,
    updated_at: &str,
) -> TaskBoardWorkflowExecutionRecord {
    let execution = create_execution(db, item_id, EARLY).await;
    set_state(
        db,
        execution,
        TaskBoardExecutionState::Running,
        None,
        updated_at,
    )
    .await
}

async fn mixed_execution(
    db: &AsyncDaemonDb,
    index: usize,
    state: TaskBoardExecutionState,
) -> TaskBoardWorkflowExecutionRecord {
    let timestamp = format!("2026-07-17T09:{index:02}:00Z");
    let execution = create_execution(db, &format!("mixed-{index:02}"), &timestamp).await;
    set_state(db, execution, state, None, &timestamp).await
}

fn owned_execution_ids(executions: &[TaskBoardWorkflowExecutionRecord]) -> Vec<String> {
    executions
        .iter()
        .map(|execution| execution.execution_id.clone())
        .collect()
}

fn mixed_ids(range: std::ops::Range<usize>) -> Vec<String> {
    range
        .map(|index| format!("execution-mixed-{index:02}"))
        .collect()
}

async fn recovery_cursor(db: &AsyncDaemonDb) -> Option<(String, String)> {
    query_as(
        "SELECT sort_updated_at, sort_execution_id
         FROM task_board_reconciliation_cursors
         WHERE queue = 'read_only_recoverable'",
    )
    .fetch_optional(db.pool())
    .await
    .expect("load recovery cursor")
}

async fn remote_candidate_cursor(db: &AsyncDaemonDb) -> Option<(String, String)> {
    query_as(
        "SELECT sort_updated_at, sort_execution_id
         FROM task_board_reconciliation_cursors
         WHERE queue = 'remote_target_candidates'",
    )
    .fetch_optional(db.pool())
    .await
    .expect("load remote-candidate cursor")
}

async fn store_cursor(db: &AsyncDaemonDb, updated_at: &str, execution_id: &str) {
    query(
        "INSERT INTO task_board_reconciliation_cursors (
             queue, sort_updated_at, sort_execution_id
         ) VALUES ('read_only_recoverable', ?1, ?2)",
    )
    .bind(updated_at)
    .bind(execution_id)
    .execute(db.pool())
    .await
    .expect("store recovery cursor");
}
