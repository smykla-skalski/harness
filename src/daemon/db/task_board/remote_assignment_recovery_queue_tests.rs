use sqlx::{Executor as _, query, query_as, query_scalar};

use super::remote_assignment_recovery_queue::{RawRecoveryCandidate, due_assignment_page};
use super::remote_assignment_test_support::{
    AFTER_EXPIRY, ControllerFixture, NOW, controller_fixture, offer_controller,
};
use crate::daemon::db::db_error;

const REPLACED_AT: &str = "2026-07-19T10:00:01Z";

#[tokio::test]
async fn deleted_assignment_cannot_leave_a_stale_quarantine_row() {
    let fixture = controller_fixture(1).await;
    let assignment = controller_assignment(&fixture).await;
    let candidate = raw_candidate(&assignment);
    query("DELETE FROM task_board_remote_assignments WHERE assignment_id = ?1")
        .bind(&assignment.assignment_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete assignment before quarantine");

    fixture
        .db
        .quarantine_remote_recovery_failure(&candidate, NOW, &db_error("poisoned evidence"))
        .await
        .expect("deleted assignment is a stale quarantine no-op");
    assert_eq!(
        quarantine_count(&fixture.db, &assignment.assignment_id).await,
        0
    );
}

#[tokio::test]
async fn replacement_generation_cannot_inherit_a_stale_quarantine_row() {
    let fixture = controller_fixture(1).await;
    let assignment = controller_assignment(&fixture).await;
    let candidate = raw_candidate(&assignment);
    replace_assignment_generation(&fixture, &assignment.assignment_id).await;

    fixture
        .db
        .quarantine_remote_recovery_failure(&candidate, NOW, &db_error("stale failure"))
        .await
        .expect("replacement generation is a stale quarantine no-op");
    assert_eq!(
        quarantine_count(&fixture.db, &assignment.assignment_id).await,
        0
    );
}

#[tokio::test]
async fn stale_recovery_snapshot_cannot_mutate_or_clear_a_replacement_generation() {
    let fixture = controller_fixture(1).await;
    let assignment = controller_assignment(&fixture).await;
    let (candidates, _) = due_assignment_page(&fixture.db, AFTER_EXPIRY)
        .await
        .expect("capture due recovery snapshot");
    let candidate = candidates
        .into_iter()
        .find(|candidate| candidate.assignment_id == assignment.assignment_id)
        .expect("assignment is due for recovery");
    replace_assignment_generation(&fixture, &assignment.assignment_id).await;
    insert_replacement_quarantine(&fixture, &assignment.assignment_id).await;

    assert!(
        fixture
            .db
            .recover_one_remote_assignment(&candidate, AFTER_EXPIRY)
            .await
            .expect("stale recovery snapshot is a no-op")
            .is_none()
    );
    let (epoch, state, updated_at, quarantine_epoch) = query_as::<_, (i64, String, String, i64)>(
        "SELECT assignments.fencing_epoch, assignments.state, assignments.updated_at,
                quarantine.fencing_epoch
         FROM task_board_remote_assignments AS assignments
         JOIN task_board_remote_recovery_quarantine AS quarantine USING (assignment_id)
         WHERE assignments.assignment_id = ?1",
    )
    .bind(&assignment.assignment_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load replacement assignment and quarantine");
    assert_eq!((epoch, quarantine_epoch), (2, 2));
    assert_eq!(state, "offered");
    assert_eq!(updated_at, REPLACED_AT);
}

#[tokio::test]
async fn a_migrated_row_never_starves_or_is_mutated_by_current_recovery_across_restart() {
    let fixture = controller_fixture(1).await;
    let assignment = controller_assignment(&fixture).await;
    insert_migrated_row(&fixture, "legacy-superseded").await;

    let (candidates, _) = due_assignment_page(&fixture.db, AFTER_EXPIRY)
        .await
        .expect("capture due recovery snapshot");
    assert!(
        candidates.iter().any(|c| c.assignment_id == assignment.assignment_id),
        "the healthy current assignment must be recoverable alongside a migrated row"
    );
    assert!(
        candidates.iter().all(|c| c.assignment_id != "legacy-superseded"),
        "a migrated row must never enter the recovery due page"
    );
    let current = candidates
        .into_iter()
        .find(|c| c.assignment_id == assignment.assignment_id)
        .expect("current candidate");
    assert!(
        fixture
            .db
            .recover_one_remote_assignment(&current, AFTER_EXPIRY)
            .await
            .expect("recover the healthy current assignment")
            .is_some(),
        "the current assignment must recover past the migrated row"
    );
    assert_migrated_untouched(&fixture.db, "legacy-superseded").await;

    // Across a restart the migrated row stays inert and out of recovery.
    let path = fixture._temp.path().join("controller.db");
    fixture.db.pool().close().await;
    let reopened = crate::daemon::db::AsyncDaemonDb::connect(&path)
        .await
        .expect("reopen controller db after recovery");
    assert_migrated_untouched(&reopened, "legacy-superseded").await;
    let (after_restart, _) = due_assignment_page(&reopened, AFTER_EXPIRY)
        .await
        .expect("due recovery snapshot after restart");
    assert!(
        after_restart.iter().all(|c| c.assignment_id != "legacy-superseded"),
        "a migrated row must stay out of recovery across restart"
    );
}

async fn insert_migrated_row(fixture: &ControllerFixture, assignment_id: &str) {
    query(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, idempotency_key, host_id, fencing_epoch,
             state, legacy_migrated, offered_at, completed_at, error, updated_at
         ) VALUES (?1, 'execution-legacy', 'planning', ?2, 'executor-a', 1, 'superseded', 1,
                   '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z', 'archived',
                   '2026-07-19T08:00:00Z')",
    )
    .bind(assignment_id)
    .bind(format!("idempotency-{assignment_id}"))
    .execute(fixture.db.pool())
    .await
    .expect("seed migrated legacy row");
}

async fn assert_migrated_untouched(db: &crate::daemon::db::AsyncDaemonDb, assignment_id: &str) {
    let (state, legacy): (String, i64) = query_as(
        "SELECT state, legacy_migrated FROM task_board_remote_assignments WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .fetch_one(db.pool())
    .await
    .expect("load migrated row");
    assert_eq!(
        (state.as_str(), legacy),
        ("superseded", 1),
        "the migrated row must be byte-identical after current recovery"
    );
    assert_eq!(
        quarantine_count(db, assignment_id).await,
        0,
        "a migrated row must never be quarantined"
    );
}

async fn controller_assignment(
    fixture: &ControllerFixture,
) -> super::TaskBoardRemoteAssignmentRecord {
    offer_controller(fixture).await;
    fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load controller assignment")
        .expect("controller assignment exists")
}

async fn replace_assignment_generation(fixture: &ControllerFixture, assignment_id: &str) {
    let mut connection = fixture
        .db
        .pool()
        .acquire()
        .await
        .expect("acquire replacement connection");
    connection
        .execute("PRAGMA ignore_check_constraints = ON")
        .await
        .expect("allow replacement generation fixture");
    query(
        "UPDATE task_board_remote_assignments
         SET fencing_epoch = fencing_epoch + 1, updated_at = ?2
         WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .bind(REPLACED_AT)
    .execute(&mut *connection)
    .await
    .expect("replace assignment generation");
    connection
        .execute("PRAGMA ignore_check_constraints = OFF")
        .await
        .expect("restore strict constraints");
}

async fn insert_replacement_quarantine(fixture: &ControllerFixture, assignment_id: &str) {
    query(
        "INSERT INTO task_board_remote_recovery_quarantine (
             assignment_id, fencing_epoch, assignment_state, assignment_updated_at,
             state_fingerprint, failure_count, next_attempt_at, last_error_code, updated_at
         ) VALUES (?1, 2, 'offered', ?2, ?3, 1, ?4, 'db_error', ?2)",
    )
    .bind(assignment_id)
    .bind(REPLACED_AT)
    .bind("b".repeat(64))
    .bind("2026-07-19T10:03:00Z")
    .execute(fixture.db.pool())
    .await
    .expect("insert replacement quarantine");
}

fn raw_candidate(assignment: &super::TaskBoardRemoteAssignmentRecord) -> RawRecoveryCandidate {
    RawRecoveryCandidate {
        assignment_id: assignment.assignment_id.clone(),
        fencing_epoch: i64::try_from(assignment.fencing_epoch).expect("fencing epoch"),
        assignment_state: assignment.state.as_str().into(),
        assignment_updated_at: assignment.updated_at.clone(),
        request_sha256: assignment.request_sha256.clone(),
        lease_id: assignment.lease_id.clone(),
    }
}

async fn quarantine_count(db: &crate::daemon::db::AsyncDaemonDb, assignment_id: &str) -> i64 {
    query_scalar(
        "SELECT COUNT(*) FROM task_board_remote_recovery_quarantine
         WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .fetch_one(db.pool())
    .await
    .expect("count quarantine rows")
}
