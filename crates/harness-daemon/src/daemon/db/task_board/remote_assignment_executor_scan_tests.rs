use sqlx::{query, query_as};

use super::remote_assignment_test_support::{
    CLAIMED_AT, ExecutorFixture, PRINCIPAL, accept_executor, claim_request, detached_offer,
    executor_fixture,
};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteMutationOutcome};

const RUNNING_AT: &str = "2026-07-19T10:00:30Z";
const TERMINAL_AT: &str = "2026-07-19T10:00:40Z";
const NEWER_CLAIM_AT: &str = "2026-07-19T10:00:50Z";

#[tokio::test]
async fn active_cursor_survives_reconnect_and_reaches_a_newer_claim() {
    let fixture = seeded_executor(65).await;
    // Claimed rows are already active for the scan (state IN claimed/started/running);
    // a raw 'running' with started_at but no start receipt violates the v43 CHECK, so
    // age the old active page by updated_at alone - all the scan cursor orders on.
    query(
        "UPDATE task_board_remote_assignments
         SET updated_at = ?1
         WHERE assignment_id < 'assignment-scan-active-064'",
    )
    .bind(RUNNING_AT)
    .execute(fixture.db.pool())
    .await
    .expect("age the old active claimed page");
    query(
        "UPDATE task_board_remote_assignments SET updated_at = ?2
         WHERE assignment_id = ?1",
    )
    .bind("assignment-scan-active-064")
    .bind(NEWER_CLAIM_AT)
    .execute(fixture.db.pool())
    .await
    .expect("make the final claim newer than the inert page");
    insert_unrelated_cursor(&fixture.db).await;

    let first = fixture
        .db
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("scan first active page");
    assert_eq!(first.active_assignment_ids.len(), 64);
    assert!(
        !first
            .active_assignment_ids
            .iter()
            .any(|id| id.ends_with("064"))
    );

    let database_path = fixture._temp.path().join("executor.db");
    let ExecutorFixture {
        db, _temp: temp, ..
    } = fixture;
    drop(db);
    let restarted = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("reopen executor database");
    let second = restarted
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("resume active scan after restart");
    assert!(
        second
            .active_assignment_ids
            .iter()
            .any(|id| id == "assignment-scan-active-064")
    );
    assert_eq!(unrelated_cursor(&restarted).await, sentinel_cursor());
    drop(restarted);
    drop(temp);
}

#[tokio::test]
async fn terminal_cursor_is_bounded_and_restart_fair() {
    let fixture = seeded_executor(65).await;
    query(
        "UPDATE task_board_remote_assignments
         SET state = 'cancelled', completed_at = ?1, updated_at = ?1",
    )
    .bind(TERMINAL_AT)
    .execute(fixture.db.pool())
    .await
    .expect("terminalize executor assignments");

    let first = fixture
        .db
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("scan first terminal page");
    assert!(first.active_assignment_ids.is_empty());
    assert_eq!(first.terminal_assignment_ids.len(), 64);
    assert!(
        !first
            .terminal_assignment_ids
            .iter()
            .any(|id| id.ends_with("064"))
    );

    let database_path = fixture._temp.path().join("executor.db");
    let ExecutorFixture {
        db, _temp: temp, ..
    } = fixture;
    drop(db);
    let restarted = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("reopen executor database");
    let second = restarted
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("resume terminal scan after restart");
    assert!(
        second
            .terminal_assignment_ids
            .iter()
            .any(|id| id == "assignment-scan-active-064")
    );
    assert!(second.terminal_assignment_ids.len() <= 64);
    drop(restarted);
    drop(temp);
}

#[tokio::test]
async fn scan_wraps_and_revisits_a_row_after_durable_state_change() {
    let fixture = seeded_executor(3).await;
    let first = fixture
        .db
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("scan initial active set");
    assert_eq!(first.active_assignment_ids.len(), 3);
    let wrapped = fixture
        .db
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("wrap active cursor");
    assert_eq!(wrapped.active_assignment_ids, first.active_assignment_ids);

    query(
        "UPDATE task_board_remote_assignments
         SET state = 'cancelled', completed_at = ?2, updated_at = ?2
         WHERE assignment_id = ?1",
    )
    .bind(&first.active_assignment_ids[0])
    .bind(TERMINAL_AT)
    .execute(fixture.db.pool())
    .await
    .expect("move active assignment into terminal work");
    let changed = fixture
        .db
        .scan_task_board_remote_executor_assignments()
        .await
        .expect("scan changed assignment state");
    assert_eq!(changed.active_assignment_ids.len(), 2);
    assert_eq!(
        changed.terminal_assignment_ids,
        vec![first.active_assignment_ids[0].clone()]
    );
}

// Each seeded assignment needs a distinct execution generation; the host inbox rejects
// two offers that share (execution_id, action_key, attempt) or (execution_id, fencing_epoch).
fn distinct_scan_offer(
    index: usize,
) -> crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest {
    let execution_id = format!("execution-scan-active-{index:03}");
    let mut request = detached_offer(
        &format!("assignment-scan-active-{index:03}"),
        &format!("scan-active-{index:03}"),
    );
    request.binding.execution_id = execution_id.clone();
    request.launch = crate::daemon::task_board_remote_transport::wire::test_codex_launch(
        crate::task_board::TaskBoardExecutionPhase::Review,
        &execution_id,
        "review:reviewer",
        "Review the frozen revision",
    );
    request.request_sha256.clear();
    request.seal().expect("seal distinct scan offer")
}

async fn seeded_executor(count: usize) -> ExecutorFixture {
    let fixture = executor_fixture(256).await;
    for index in 0..count {
        let request = distinct_scan_offer(index);
        let accepted = accept_executor(&fixture, &request).await;
        assert!(matches!(
            fixture
                .db
                .claim_task_board_remote_assignment(
                    &claim_request(&request, &accepted),
                    PRINCIPAL,
                    CLAIMED_AT,
                )
                .await
                .expect("claim executor scan fixture"),
            TaskBoardRemoteMutationOutcome::Updated(_)
        ));
    }
    fixture
}

async fn insert_unrelated_cursor(db: &AsyncDaemonDb) {
    let (updated_at, execution_id) = sentinel_cursor();
    query(
        "INSERT INTO task_board_reconciliation_cursors (
             queue, sort_updated_at, sort_execution_id
         ) VALUES ('unrelated-sentinel', ?1, ?2)",
    )
    .bind(updated_at)
    .bind(execution_id)
    .execute(db.pool())
    .await
    .expect("insert unrelated cursor");
}

async fn unrelated_cursor(db: &AsyncDaemonDb) -> (String, String) {
    query_as(
        "SELECT sort_updated_at, sort_execution_id
         FROM task_board_reconciliation_cursors WHERE queue = 'unrelated-sentinel'",
    )
    .fetch_one(db.pool())
    .await
    .expect("load unrelated cursor")
}

fn sentinel_cursor() -> (String, String) {
    ("2026-01-01T00:00:00Z".into(), "sentinel-execution".into())
}
