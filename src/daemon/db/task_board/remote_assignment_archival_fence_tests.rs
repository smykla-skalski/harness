use super::TaskBoardRemoteOfferOutcome;
use super::remote_assignment_test_support::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{TaskBoardExecutionAttemptCas, TaskBoardWorkflowExecutionCas};

#[tokio::test]
async fn controller_offer_rejects_archival_idempotency_collision_without_mutation() {
    let fixture = controller_fixture(2).await;
    // A frozen legacy (archival) row already owns this offer's idempotency key
    // under a different assignment id. The partial unique index, the typed
    // collision query, and the active-state idempotency guards all scope to
    // legacy_migrated = 0, so only the archival fence can see this.
    insert_archival_assignment(
        &fixture.db,
        "legacy-archived-1",
        &fixture.request.binding.idempotency_key,
        "execution-legacy",
        1,
    )
    .await;
    let before = sequence(&fixture.db).await;

    let error = offer_expect_err(&fixture).await;

    assert!(
        error.contains("collides with archived legacy assignment 'legacy-archived-1'"),
        "unexpected error: {error}"
    );
    assert_zero_mutation(&fixture, before).await;
}

#[tokio::test]
async fn controller_offer_rejects_archival_assignment_id_collision_without_mutation() {
    let fixture = controller_fixture(2).await;
    // The archival row shares the offer's assignment id. The primary key would
    // also reject the insert, but the fence converts it to a deterministic
    // ConcurrentModification before any mutation is attempted.
    insert_archival_assignment(
        &fixture.db,
        &fixture.request.binding.assignment_id,
        "legacy-idempotency-distinct",
        "execution-legacy",
        1,
    )
    .await;
    let before = sequence(&fixture.db).await;

    let error = offer_expect_err(&fixture).await;

    assert!(
        error.contains(&format!(
            "collides with archived legacy assignment '{}'",
            fixture.request.binding.assignment_id
        )),
        "unexpected error: {error}"
    );
    assert_zero_mutation(&fixture, before).await;
}

#[tokio::test]
async fn controller_offer_rejects_archival_generation_collision_without_mutation() {
    let fixture = controller_fixture(2).await;
    // The archival row preserves the offer's exact (execution_id, fencing_epoch)
    // generation under an otherwise-distinct identity. The current execution-epoch
    // unique index scopes to legacy_migrated = 0, so only the fence catches it.
    let epoch = i64::try_from(fixture.request.binding.fencing_epoch).expect("epoch fits i64");
    insert_archival_assignment(
        &fixture.db,
        "legacy-generation",
        "legacy-generation-key",
        &fixture.request.binding.execution_id,
        epoch,
    )
    .await;
    let before = sequence(&fixture.db).await;

    let error = offer_expect_err(&fixture).await;

    assert!(
        error.contains("collides with archived legacy assignment 'legacy-generation'"),
        "unexpected error: {error}"
    );
    assert_zero_mutation(&fixture, before).await;
}

#[tokio::test]
async fn controller_offer_replays_unchanged_beside_noncolliding_archival_row() {
    let fixture = controller_fixture(2).await;
    // A fully distinct archival row must never interfere with the current exact
    // replay path: the fence is a pure no-op when nothing collides.
    insert_archival_assignment(
        &fixture.db,
        "legacy-unrelated",
        "legacy-key-unrelated",
        "execution-legacy",
        1,
    )
    .await;

    let created = offer_controller(&fixture).await;
    assert!(
        matches!(created, TaskBoardRemoteOfferOutcome::Created(_)),
        "first offer should create, got {created:?}"
    );
    let replayed = offer_controller(&fixture).await;
    assert!(
        matches!(replayed, TaskBoardRemoteOfferOutcome::Replayed(_)),
        "second identical offer should replay, got {replayed:?}"
    );
}

#[tokio::test]
async fn executor_inbox_rejects_archival_idempotency_collision_without_mutation() {
    let fixture = executor_fixture(2).await;
    insert_archival_assignment(
        &fixture.db,
        "legacy-archived-inbox",
        &fixture.request.binding.idempotency_key,
        "execution-legacy",
        1,
    )
    .await;
    let before = sequence(&fixture.db).await;

    let error = fixture
        .db
        .accept_task_board_remote_assignment_offer(&fixture.request, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect_err("archival idempotency collision must fail closed on the inbox")
        .to_string();

    assert!(
        error.contains("collides with archived legacy assignment 'legacy-archived-inbox'"),
        "unexpected error: {error}"
    );
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&fixture.request.binding.assignment_id)
            .await
            .expect("load current assignment")
            .is_none(),
        "the refused accept must not create a current assignment"
    );
    assert_eq!(
        remote_assignment_row_count(&fixture.db).await,
        1,
        "only the untouched archival row may remain"
    );
    assert_eq!(
        sequence(&fixture.db).await,
        before,
        "a refused accept must not bump the change sequence"
    );
}

async fn offer_expect_err(fixture: &ControllerFixture) -> String {
    fixture
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
            &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
            &fixture.request,
            HOST,
            NOW,
            LEASE_EXPIRES,
            DEADLINE,
        )
        .await
        .expect_err("archival identity collision must fail closed")
        .to_string()
}

/// After a refused offer nothing may have changed: no current assignment for the
/// offered id, the archival row still exactly one, and the change sequence flat.
async fn assert_zero_mutation(fixture: &ControllerFixture, before: i64) {
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&fixture.request.binding.assignment_id)
            .await
            .expect("load current assignment")
            .is_none(),
        "the refused offer must not create a current assignment"
    );
    assert_eq!(
        remote_assignment_row_count(&fixture.db).await,
        1,
        "only the untouched archival row may remain"
    );
    assert_eq!(
        sequence(&fixture.db).await,
        before,
        "a refused offer must not bump the change sequence"
    );
}

async fn insert_archival_assignment(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    idempotency_key: &str,
    execution_id: &str,
    fencing_epoch: i64,
) {
    // Mirror the minimal valid superseded legacy row the v43 migration produces:
    // offered_at == completed_at, every other timestamp and evidence column NULL.
    sqlx::query(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, idempotency_key, host_id,
             fencing_epoch, state, legacy_migrated, offered_at, completed_at, error,
             updated_at
         ) VALUES (
             ?1, ?4, 'planning', ?2, ?3, ?5, 'superseded', 1,
             '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z',
             'migrated from dormant v36 assignment; never executable',
             '2026-07-19T08:00:00Z'
         )",
    )
    .bind(assignment_id)
    .bind(idempotency_key)
    .bind(HOST)
    .bind(execution_id)
    .bind(fencing_epoch)
    .execute(db.pool())
    .await
    .expect("insert archival legacy assignment");
}

async fn remote_assignment_row_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_remote_assignments")
        .fetch_one(db.pool())
        .await
        .expect("count remote assignments")
}

async fn sequence(db: &AsyncDaemonDb) -> i64 {
    db.current_change_sequence()
        .await
        .expect("read change sequence")
}
