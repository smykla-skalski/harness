use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_test_support::{
    HOST, INSTANCE, NOW, REPOSITORY, controller_fixture, offer_controller,
};
use super::remote_operation_trust::{
    claim_cleanup_observation_trust_in_tx, claim_controller_operation_trust_in_tx,
    consume_cleanup_observation_trust_in_tx,
};
use super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome, TaskBoardRemoteOperationKind,
    TaskBoardRemoteOperationTrustFence,
};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{
    TASK_BOARD_REMOTE_PROTOCOL_VERSION, TaskBoardExecutionHostAdvertisement,
    TaskBoardPhaseCapabilityProfile,
};

const STATUS_SHA256: &str =
    "1111111111111111111111111111111111111111111111111111111111111111";
const CANCEL_SHA256: &str =
    "2222222222222222222222222222222222222222222222222222222222222222";
const SETTLE_SHA256: &str =
    "3333333333333333333333333333333333333333333333333333333333333333";
const FETCH_SHA256: &str =
    "4444444444444444444444444444444444444444444444444444444444444444";
const FRESH_SHA256: &str =
    "5555555555555555555555555555555555555555555555555555555555555555";
const CLEANUP_SHA256: &str =
    "6666666666666666666666666666666666666666666666666666666666666666";
const PARENT_SHA256: &str =
    "7777777777777777777777777777777777777777777777777777777777777777";

#[tokio::test]
async fn disabled_r2_lifecycle_operations_use_the_frozen_generation_and_survive_restart() {
    let fixture = controller_fixture(1).await;
    let assignment = created_assignment(&fixture).await;
    let r1 = assignment
        .configuration_revision
        .expect("controller assignment revision");
    let r2 = disable_controller_host(&fixture.db).await;
    assert!(r2 > r1);

    for (kind, digest) in [
        (TaskBoardRemoteOperationKind::Status, STATUS_SHA256),
        (TaskBoardRemoteOperationKind::Cancel, CANCEL_SHA256),
        (TaskBoardRemoteOperationKind::FetchArtifact, FETCH_SHA256),
    ] {
        let trust = lifecycle_trust(&fixture.db, &assignment, kind).await;
        assert!(!trust.host.config.enabled);
        assert_eq!(trust.host.configuration_revision, r2);
        assert_eq!(trust.observed_host_instance_id, INSTANCE);
        claim_operation(
            &fixture.db,
            &assignment.assignment_id,
            kind,
            digest,
            Some(&trust),
        )
        .await
        .expect("claim disabled-host lifecycle authority");
        assert_operation_fence(&fixture.db, &assignment.assignment_id, &trust).await;
        fixture
            .db
            .complete_task_board_remote_operation_trust(&assignment.assignment_id, kind, digest)
            .await
            .expect("consume disabled-host lifecycle authority");
    }

    assert!(
        claim_operation(
            &fixture.db,
            &assignment.assignment_id,
            TaskBoardRemoteOperationKind::Renew,
            FRESH_SHA256,
            None,
        )
        .await
        .is_err()
    );
    assert_no_operation(&fixture.db, &assignment.assignment_id).await;

    let settle = lifecycle_trust(
        &fixture.db,
        &assignment,
        TaskBoardRemoteOperationKind::Settle,
    )
    .await;
    claim_operation(
        &fixture.db,
        &assignment.assignment_id,
        TaskBoardRemoteOperationKind::Settle,
        SETTLE_SHA256,
        Some(&settle),
    )
    .await
    .expect("claim restart-stable lifecycle authority");
    let path = fixture._temp.path().join("controller.db");
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&path)
        .await
        .expect("restart controller database");
    assert_operation_fence(&restarted, &assignment.assignment_id, &settle).await;
    restarted
        .complete_task_board_remote_operation_trust(
            &assignment.assignment_id,
            TaskBoardRemoteOperationKind::Settle,
            SETTLE_SHA256,
        )
        .await
        .expect("consume lifecycle authority after restart");
}

#[tokio::test]
async fn successor_r2_fences_lifecycle_calls_but_not_fresh_offer_or_renew() {
    let fixture = controller_fixture(1).await;
    let assignment = created_assignment(&fixture).await;
    let r1 = assignment
        .configuration_revision
        .expect("controller assignment revision");
    let r2 = rotate_controller_revision(&fixture.db).await;
    assert!(r2 > r1);
    record_successor_observation(&fixture.db).await;

    let lifecycle = lifecycle_trust(
        &fixture.db,
        &assignment,
        TaskBoardRemoteOperationKind::Status,
    )
    .await;
    assert_eq!(lifecycle.host.configuration_revision, r2);
    assert_eq!(lifecycle.observed_host_instance_id, "instance-b");
    claim_operation(
        &fixture.db,
        &assignment.assignment_id,
        TaskBoardRemoteOperationKind::Status,
        STATUS_SHA256,
        Some(&lifecycle),
    )
    .await
    .expect("claim successor-fenced lifecycle authority");
    assert_operation_fence(&fixture.db, &assignment.assignment_id, &lifecycle).await;
    fixture
        .db
        .complete_task_board_remote_operation_trust(
            &assignment.assignment_id,
            TaskBoardRemoteOperationKind::Status,
            STATUS_SHA256,
        )
        .await
        .expect("consume successor-fenced lifecycle authority");

    let fresh = fixture
        .db
        .task_board_remote_operation_trust_fence(HOST)
        .await
        .expect("load fresh successor host fence");
    for kind in [
        TaskBoardRemoteOperationKind::Offer,
        TaskBoardRemoteOperationKind::Renew,
    ] {
        let error = claim_operation(
            &fixture.db,
            &assignment.assignment_id,
            kind,
            FRESH_SHA256,
            Some(&fresh),
        )
        .await
        .expect_err("fresh operation must not cross the assignment generation");
        assert!(error.to_string().contains("configured host evidence"));
        assert_no_operation(&fixture.db, &assignment.assignment_id).await;
    }
}

#[tokio::test]
async fn cleanup_observation_rolls_a_stale_per_call_fence_after_restart() {
    let fixture = controller_fixture(1).await;
    let assignment = created_assignment(&fixture).await;
    let r1 = fixture
        .db
        .task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load r1 cleanup trust");
    claim_cleanup(
        &fixture.db,
        &assignment.assignment_id,
        CLEANUP_SHA256,
        PARENT_SHA256,
        &r1,
    )
    .await
    .expect("claim r1 cleanup observation");

    let r2_revision = rotate_controller_revision(&fixture.db).await;
    let r2 = fixture
        .db
        .task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load r2 cleanup trust");
    assert_eq!(r2.configuration_revision, r2_revision);
    assert!(r2.configuration_revision > r1.configuration_revision);
    assert!(
        consume_cleanup(
            &fixture.db,
            &assignment.assignment_id,
            CLEANUP_SHA256,
            PARENT_SHA256,
            &r1,
        )
        .await
        .is_err()
    );

    let path = fixture._temp.path().join("controller.db");
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&path)
        .await
        .expect("restart controller database");
    claim_cleanup(
        &restarted,
        &assignment.assignment_id,
        CLEANUP_SHA256,
        PARENT_SHA256,
        &r2,
    )
    .await
    .expect("roll cleanup observation to r2");
    let current = restarted
        .task_board_remote_lifecycle_operation_trust_fence(
            &assignment.assignment_id,
            TaskBoardRemoteOperationKind::ObserveCleanup,
        )
        .await
        .expect("load r2 cleanup operation fence");
    assert_operation_fence(&restarted, &assignment.assignment_id, &current).await;
    consume_cleanup(
        &restarted,
        &assignment.assignment_id,
        CLEANUP_SHA256,
        PARENT_SHA256,
        &r2,
    )
    .await
    .expect("consume rolled cleanup observation");
    assert_no_operation(&restarted, &assignment.assignment_id).await;
}

async fn created_assignment(
    fixture: &super::remote_assignment_test_support::ControllerFixture,
) -> TaskBoardRemoteAssignmentRecord {
    match offer_controller(fixture).await {
        TaskBoardRemoteOfferOutcome::Created(record) => record,
        other => panic!("expected created controller assignment, got {other:?}"),
    }
}

async fn disable_controller_host(db: &AsyncDaemonDb) -> u64 {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load controller settings");
    settings.execution_hosts[0].enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable controller host");
    db.task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load disabled host fence")
        .configuration_revision
}

async fn rotate_controller_revision(db: &AsyncDaemonDb) -> u64 {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load controller settings");
    settings.retry.max_attempts = settings.retry.max_attempts.saturating_add(1);
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("rotate controller revision");
    db.task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load rotated host fence")
        .configuration_revision
}

async fn record_successor_observation(db: &AsyncDaemonDb) {
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: HOST.into(),
            host_instance_id: "instance-b".into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec![REPOSITORY.into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
            capacity: 1,
            active_assignments: 1,
            heartbeat_at: NOW.into(),
        },
        NOW,
    )
    .await
    .expect("record successor observation");
}

async fn lifecycle_trust(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
) -> TaskBoardRemoteOperationTrustFence {
    db.task_board_remote_lifecycle_operation_trust_fence(&assignment.assignment_id, kind)
        .await
        .expect("load lifecycle operation fence")
}

async fn claim_operation(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    expected: Option<&TaskBoardRemoteOperationTrustFence>,
) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("test remote lifecycle operation trust")
        .await?;
    let assignment = require_assignment(&mut transaction, assignment_id).await?;
    let result = claim_controller_operation_trust_in_tx(
        &mut transaction,
        &assignment,
        kind,
        request_sha256,
        expected,
    )
    .await;
    if result.is_ok() {
        transaction
            .commit()
            .await
            .expect("commit lifecycle operation authority");
    }
    result
}

async fn claim_cleanup(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    request_sha256: &str,
    parent_sha256: &str,
    expected: &crate::daemon::db::TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    let mut transaction = db
        .begin_immediate_transaction("test remote cleanup operation trust claim")
        .await?;
    let assignment = require_assignment(&mut transaction, assignment_id).await?;
    claim_cleanup_observation_trust_in_tx(
        &mut transaction,
        &assignment,
        request_sha256,
        parent_sha256,
        expected,
    )
    .await?;
    transaction
        .commit()
        .await
        .expect("commit cleanup operation authority");
    Ok(())
}

async fn consume_cleanup(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    request_sha256: &str,
    parent_sha256: &str,
    expected: &crate::daemon::db::TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    let mut transaction = db
        .begin_immediate_transaction("test remote cleanup operation trust consume")
        .await?;
    let assignment = require_assignment(&mut transaction, assignment_id).await?;
    consume_cleanup_observation_trust_in_tx(
        &mut transaction,
        &assignment,
        request_sha256,
        parent_sha256,
        expected,
    )
    .await?;
    transaction
        .commit()
        .await
        .expect("commit cleanup operation response");
    Ok(())
}

async fn assert_operation_fence(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    expected: &TaskBoardRemoteOperationTrustFence,
) {
    let operation = db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load operation-fenced assignment")
        .expect("operation-fenced assignment")
        .controller_operation
        .expect("controller operation token");
    let fence = operation.fence.expect("controller operation lifecycle fence");
    assert_eq!(fence.configuration_revision, expected.host.configuration_revision);
    assert_eq!(fence.enabled_at_capture, expected.host.config.enabled);
    assert_eq!(
        fence.observed_host_instance_id,
        expected.observed_host_instance_id
    );
    assert_eq!(fence.advertisement_sha256, expected.advertisement_sha256);
}

async fn assert_no_operation(db: &AsyncDaemonDb, assignment_id: &str) {
    assert!(
        db.task_board_remote_assignment(assignment_id)
            .await
            .expect("load assignment without operation")
            .expect("assignment without operation")
            .controller_operation
            .is_none()
    );
}
