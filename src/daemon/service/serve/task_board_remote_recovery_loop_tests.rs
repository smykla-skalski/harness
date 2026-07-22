use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};
use sqlx::{Executor as _, query, query_scalar};

use super::*;
use crate::daemon::db::{
    PreparedRemoteOffer, REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture,
    TaskBoardRemoteOfferOutcome, authorize_and_start_remote_executor, prepare_remote_offer,
    remote_executor_claim_request, remote_executor_fixture,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteCancelRequest, RemoteOfferRequest, RemoteSettledRequest,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_PROTOCOL_VERSION, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionHostAdvertisement, TaskBoardItem, TaskBoardPhaseCapabilityProfile,
    TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
};

#[test]
fn recovery_schedule_uses_earlier_remote_deadline_and_backs_off_failures() {
    let fallback = Duration::from_secs(30);
    let deadline =
        (Utc::now() + ChronoDuration::seconds(5)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let scheduled = next_deadline(Some(&deadline), fallback).expect("remote deadline");
    assert!(scheduled <= Instant::now() + Duration::from_secs(6));

    let expired = (Utc::now() - ChronoDuration::seconds(5))
        .to_rfc3339_opts(SecondsFormat::Secs, true);
    let expired_wake = next_deadline(Some(&expired), fallback).expect("expired remote deadline");
    assert!(expired_wake >= Instant::now() + Duration::from_millis(900));
    assert!(expired_wake <= Instant::now() + Duration::from_secs(2));

    let mut schedule = RecoverySchedule::new(fallback);
    schedule.record_failure();
    assert!(schedule.next_wake >= Instant::now() + Duration::from_millis(900));
    assert!(schedule.next_wake <= Instant::now() + Duration::from_secs(2));

    let mut incomplete = RecoverySchedule::new(fallback);
    incomplete.record_batch(
        &TaskBoardRemoteRecoveryBatch {
            incomplete: true,
            ..TaskBoardRemoteRecoveryBatch::default()
        },
        None,
    );
    assert!(incomplete.next_wake >= Instant::now() + Duration::from_millis(900));
    assert!(incomplete.next_wake <= Instant::now() + Duration::from_secs(2));

    let mut quarantined = RecoverySchedule::new(fallback);
    quarantined.consecutive_failures = 4;
    quarantined.record_batch(
        &TaskBoardRemoteRecoveryBatch {
            failures: vec![crate::daemon::db::TaskBoardRemoteRecoveryFailure {
                assignment_id: "poisoned-assignment".into(),
                code: "malformed_evidence".into(),
                message: "quarantined".into(),
            }],
            ..TaskBoardRemoteRecoveryBatch::default()
        },
        None,
    );
    assert_eq!(quarantined.consecutive_failures, 0);
    assert!(quarantined.next_wake <= Instant::now() + fallback);
}

#[tokio::test]
async fn foreground_recovery_drains_poisoned_incomplete_pages_before_unrelated_callback() {
    let fixture = poisoned_recovery_fixture(130).await;
    assert!(
        fixture
            .db
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("load exact active fence")
    );

    recover_remote_assignments_before_work(&fixture.db)
        .await
        .expect("foreground recovery drains the quarantined incomplete page");
    assert_eq!(quarantine_count(&fixture.db, "zzz-healthy").await, 0);
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment("zzz-healthy")
            .await
            .expect("load foreground-recovered healthy assignment")
            .expect("healthy assignment")
            .state,
        TaskBoardRemoteAssignmentState::Superseded
    );
    assert!(
        !fixture
            .db
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("drained recovery releases its exact remote fence")
    );
    fixture
        .db
        .create_task_board_item(TaskBoardItem::new(
            "unrelated-local-callback".into(),
            "Unrelated local callback".into(),
            "Must progress past quarantined remote evidence".into(),
            fixture.offered_at.clone(),
        ))
        .await
        .expect("run unrelated downstream database callback");
    assert_eq!(
        fixture
            .db
            .task_board_item("unrelated-local-callback")
            .await
            .expect("load unrelated callback item")
            .id,
        "unrelated-local-callback"
    );
}

#[tokio::test]
async fn startup_tolerates_quarantine_and_bounded_backlog() {
    let fixture = poisoned_recovery_fixture(130).await;
    recover_remote_assignments_at_startup(&fixture.db)
        .await
        .expect("startup leaves poisoned rows fenced for background recovery");
    assert_eq!(quarantine_count(&fixture.db, "zzz-healthy").await, 0);
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment("zzz-healthy")
            .await
            .expect("load startup-recovered assignment")
            .expect("startup-recovered assignment")
            .state,
        TaskBoardRemoteAssignmentState::Superseded
    );
    assert!(
        !fixture
            .db
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("startup recovery releases its remote fence")
    );
}

#[tokio::test]
async fn top_level_recovery_query_failure_still_blocks_callback() {
    let directory = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("broken.db"))
        .await
        .expect("open recovery db");
    query("ALTER TABLE task_board_remote_assignments RENAME TO unavailable_assignments")
        .execute(db.pool())
        .await
        .expect("break top-level recovery query");

    let recovered = recover_remote_assignments_before_work(&db).await;
    let callback_ran = recovered.is_ok();
    assert!(recovered.is_err());
    assert!(!callback_ran);
}

#[tokio::test]
async fn background_expiry_waits_for_the_last_controller_page() {
    let fixture = poisoned_recovery_fixture(65).await;
    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));

    maintain_remote_recovery_after_coverage(&fixture.db, &mut schedule, true, true).await;
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment("zzz-healthy")
            .await
            .expect("load unvisited controller assignment")
            .expect("unvisited controller assignment")
            .state,
        TaskBoardRemoteAssignmentState::Offered
    );
    assert!(
        fixture
            .db
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("load exact active fence before the last controller page")
    );

    maintain_remote_recovery_after_coverage(&fixture.db, &mut schedule, false, false).await;
    assert_eq!(
        fixture
            .db
            .task_board_remote_assignment("zzz-healthy")
            .await
            .expect("load controller-covered assignment")
            .expect("controller-covered assignment")
            .state,
        TaskBoardRemoteAssignmentState::Superseded
    );
}

#[tokio::test]
async fn background_maintenance_prunes_only_cleanup_completed_evidence() {
    let fixture = settled_old_fixture().await;

    let mut schedule = RecoverySchedule::new(Duration::from_secs(30));
    maintain_remote_recovery(&fixture.executor.db, &mut schedule).await;
    assert!(
        fixture
            .executor
            .db
            .task_board_remote_settlement_receipt(&fixture.offer.binding.assignment_id)
            .await
            .expect("load settlement before cleanup")
            .is_some()
    );
    fixture
        .executor
        .db
        .complete_task_board_remote_assignment_cleanup(
            &fixture.settlement,
            REMOTE_EXECUTOR_PRINCIPAL,
            &fixture.cleanup_completed_at,
        )
        .await
        .expect("mark old executor cleanup complete");
    maintain_remote_recovery(&fixture.executor.db, &mut schedule).await;

    assert!(
        fixture
            .executor
            .db
            .task_board_remote_settlement_receipt(&fixture.offer.binding.assignment_id)
            .await
            .expect("load pruned settlement receipt")
            .is_none()
    );
    assert_eq!(
        offer_receipt_count(&fixture.executor.db, &fixture.offer.binding.assignment_id,).await,
        0
    );
    let assignment = fixture
        .executor
        .db
        .task_board_remote_assignment(&fixture.offer.binding.assignment_id)
        .await
        .expect("load retained assignment")
        .expect("retained assignment");
    assert_eq!(
        assignment.cleanup_settlement_request_sha256.as_deref(),
        Some(fixture.settlement.request_sha256.as_str())
    );
    assert_eq!(
        assignment.cleanup_completed_at.as_deref(),
        Some(fixture.cleanup_completed_at.as_str())
    );
    assert_eq!(
        fixture
            .executor
            .db
            .task_board_remote_executor_active_assignment_count(&fixture.offer.binding.host_id)
            .await
            .expect("load executor active count"),
        0
    );
}

struct SettledOldFixture {
    executor: RemoteExecutorFixture,
    offer: RemoteOfferRequest,
    settlement: RemoteSettledRequest,
    cleanup_completed_at: String,
}

async fn settled_old_fixture() -> SettledOldFixture {
    let executor = remote_executor_fixture(1).await;
    let origin = Utc::now() - ChronoDuration::days(10);
    let at = |seconds| {
        (origin + ChronoDuration::seconds(seconds)).to_rfc3339_opts(SecondsFormat::Secs, true)
    };
    let mut offer = executor.request.clone();
    offer.deadline_at = at(120);
    offer = offer.seal().expect("seal retained old offer");
    let accepted = match executor
        .db
        .accept_task_board_remote_assignment_offer(
            &offer,
            REMOTE_EXECUTOR_PRINCIPAL,
            &offer.binding.host_instance_id,
            &at(0),
        )
        .await
        .expect("accept old executor offer")
    {
        TaskBoardRemoteOfferOutcome::Created(record) => record,
        other => panic!("expected created executor offer, got {other:?}"),
    };
    let claim = remote_executor_claim_request(&offer, &accepted);
    executor
        .db
        .claim_task_board_remote_assignment(&claim, REMOTE_EXECUTOR_PRINCIPAL, &at(1))
        .await
        .expect("claim old executor assignment");
    authorize_and_start_remote_executor(&executor, &accepted.assignment_id, &at(2)).await;
    let lease_id = accepted.lease_id.expect("accepted executor lease");
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        reason: "controller cancelled old assignment".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal old cancellation");
    executor
        .db
        .cancel_task_board_remote_assignment(&cancel, REMOTE_EXECUTOR_PRINCIPAL, &at(3))
        .await
        .expect("cancel old executor assignment");
    let settlement = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id,
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Cancelled,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal old settlement");
    executor
        .db
        .settle_task_board_remote_assignment(&settlement, REMOTE_EXECUTOR_PRINCIPAL, &at(4))
        .await
        .expect("settle old executor assignment");
    let cleanup_completed_at = at(5);
    SettledOldFixture {
        executor,
        offer,
        settlement,
        cleanup_completed_at,
    }
}

async fn poisoned_recovery_fixture(poison_count: u32) -> RecoveryFixture {
    let mut prepared = prepare_remote_offer("recovery-liveness-healthy").await;
    let now = Utc::now() + ChronoDuration::seconds(1);
    let offered_at = now.to_rfc3339_opts(SecondsFormat::Secs, true);
    let lease_expires_at =
        (now + ChronoDuration::seconds(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
    prepared.offer.binding.assignment_id = "zzz-healthy".into();
    prepared.offer.lease_seconds = 1;
    prepared.offer.deadline_at =
        (now + ChronoDuration::minutes(10)).to_rfc3339_opts(SecondsFormat::Secs, true);
    prepared.offer = prepared.offer.clone().seal().expect("reseal healthy offer");
    prepared
        .db
        .record_task_board_execution_host_observation(
            &TaskBoardExecutionHostAdvertisement {
                host_id: "executor-a".into(),
                host_instance_id: "instance-a".into(),
                protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
                repositories: vec!["example/harness".into()],
                runtimes: vec!["codex".into()],
                capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
                capacity: 1,
                active_assignments: 0,
                heartbeat_at: offered_at.clone(),
            },
            &offered_at,
        )
        .await
        .expect("refresh healthy recovery host");
    let outcome = prepared
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&prepared.execution),
            &TaskBoardExecutionAttemptCas::from(&prepared.attempt),
            &prepared.offer,
            "executor-a",
            &offered_at,
            &lease_expires_at,
            &prepared.offer.deadline_at,
        )
        .await
        .expect("persist healthy due assignment");
    assert!(matches!(outcome, TaskBoardRemoteOfferOutcome::Created(_)));
    assert!(
        prepared
            .db
            .claim_task_board_remote_offer_io_authority(&prepared.offer, "executor-a", &offered_at,)
            .await
            .expect("fence healthy assignment")
            .is_some()
    );
    insert_malformed_assignments(&prepared.db, poison_count).await;
    tokio::time::sleep(Duration::from_millis(2_200)).await;
    let execution = prepared.execution.clone();
    RecoveryFixture {
        db: (*prepared.db).clone(),
        _prepared: prepared,
        execution,
        offered_at,
    }
}

struct RecoveryFixture {
    db: AsyncDaemonDb,
    _prepared: PreparedRemoteOffer,
    execution: crate::task_board::TaskBoardWorkflowExecutionRecord,
    offered_at: String,
}

async fn insert_malformed_assignments(db: &AsyncDaemonDb, count: u32) {
    let mut connection = db
        .pool()
        .acquire()
        .await
        .expect("acquire poison connection");
    connection
        .execute("PRAGMA ignore_check_constraints = ON")
        .await
        .expect("allow persisted malformed evidence");
    query(
        "WITH RECURSIVE sequence(value) AS (
             SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < ?2
         )
         INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
             host_id, target_host_instance_id, claimed_host_instance_id, lease_id,
             fencing_epoch, configuration_revision, execution_record_sha256,
             request_sha256, request_json, authenticated_principal,
             last_mutation_kind, last_mutation_sha256, state, legacy_migrated,
             offered_at, claimed_at, started_at, heartbeat_at, lease_expires_at,
             deadline_at, cancel_requested_at, completed_at, workspace_ref,
             executor_configuration_revision, executor_checkout_path, result_json,
             status_sha256, result_sha256, cleanup_settlement_request_sha256,
             cleanup_completed_at, error, updated_at
         )
         SELECT printf('aaa-poison-%03d', value),
                printf('poison-execution-%03d', value),
                phase, action_key, attempt, printf('poison-key-%03d', value),
                host_id, target_host_instance_id, claimed_host_instance_id, lease_id,
                1000 + value, configuration_revision, execution_record_sha256,
                printf('%064x', 10000 + value), request_json, authenticated_principal,
                last_mutation_kind, last_mutation_sha256, state, legacy_migrated,
                offered_at, claimed_at, started_at, heartbeat_at, lease_expires_at,
                deadline_at, cancel_requested_at, completed_at, workspace_ref,
                executor_configuration_revision, executor_checkout_path, result_json,
                status_sha256, result_sha256, cleanup_settlement_request_sha256,
                cleanup_completed_at, error, updated_at
         FROM task_board_remote_assignments, sequence
         WHERE assignment_id = ?1",
    )
    .bind("zzz-healthy")
    .bind(i64::from(count))
    .execute(&mut *connection)
    .await
    .expect("persist malformed recovery rows");
    connection
        .execute("PRAGMA ignore_check_constraints = OFF")
        .await
        .expect("restore strict constraints");
}

async fn quarantine_count(db: &AsyncDaemonDb, assignment_id: &str) -> i64 {
    query_scalar(
        "SELECT COUNT(*) FROM task_board_remote_recovery_quarantine
         WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .fetch_one(db.pool())
    .await
    .expect("load recovery quarantine count")
}

async fn offer_receipt_count(db: &AsyncDaemonDb, assignment_id: &str) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_offer_receipts WHERE assignment_id = ?1")
        .bind(assignment_id)
        .fetch_one(db.pool())
        .await
        .expect("load remote receipt count")
}
