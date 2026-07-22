use std::path::Path;
use std::sync::Arc;

use sqlx::{query, query_scalar};
use tokio::sync::Barrier;

use super::remote_assignment_test_support::*;
use super::{
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopReason,
    TaskBoardRemoteExecutorStartAuthority, TaskBoardRemoteMutationOutcome,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLeaseRenewRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn renewed_claim_can_acquire_exact_start_authority_once() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let claimed = load_assignment(&fixture, &accepted.assignment_id).await;
    let immutable_receipt = claimed.claim_receipt.clone();
    let old_lease = claimed.lease_id.clone().expect("initial lease");
    let renewal = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: old_lease,
        offer_request_sha256: fixture.request.request_sha256.clone(),
        extend_seconds: 60,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal");
    let renewed = match fixture
        .db
        .renew_task_board_remote_assignment_lease(
            &renewal,
            PRINCIPAL,
            "2026-07-19T10:00:30Z",
        )
        .await
        .expect("renew before executor start")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected renewed claim, got {other:?}"),
    };
    assert_ne!(renewed.lease_id.as_deref(), Some(renewal.lease_id.as_str()));
    assert_eq!(renewed.claim_receipt, immutable_receipt);

    let authority = replay_start_authority(&fixture, &accepted.assignment_id).await;

    let (project_dir, permit) = persist_executor_run(
        &fixture,
        &renewed,
        &authority,
        "2026-07-19T10:00:40Z",
    )
    .await;
    assert!(matches!(
        fixture
            .db
            .adopt_task_board_remote_executor_start(
                &permit,
                Path::new(&project_dir),
                "2026-07-19T10:00:40Z",
            )
            .await
            .expect("adopt renewed exact start"),
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Started
    ));
    let stale_l1 = claim_request(&fixture.request, &claimed);
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(&stale_l1, PRINCIPAL, CLAIMED_AT)
            .await
            .expect("replay immutable L1 claim after L2 start"),
        TaskBoardRemoteMutationOutcome::Replayed(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Started
                && record.lease_id == renewed.lease_id
                && record.claim_receipt == immutable_receipt
    ));
    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_start_authority(
                &accepted.assignment_id,
                INSTANCE,
                "2026-07-19T10:00:41Z",
            )
            .await
            .expect("reject second start authority")
            .is_none()
    );
    let runs = query_scalar::<_, i64>("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count deterministic executor runs");
    assert_eq!(runs, 1);
}

#[tokio::test]
async fn recovery_winner_prevents_a_late_start_authority() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let recovered = fixture
        .db
        .recover_task_board_remote_assignments(AFTER_EXPIRY)
        .await
        .expect("expire claim before authority");
    assert_eq!(recovered.recovered.len(), 1);
    assert_eq!(recovered.recovered[0].state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_start_authority(
                &accepted.assignment_id,
                INSTANCE,
                STARTED_AT,
            )
            .await
            .expect("reject authority after recovery")
            .is_none()
    );
}

#[tokio::test]
async fn concurrent_recovery_and_start_authority_have_one_atomic_winner() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let barrier = Arc::new(Barrier::new(3));
    let authority_db = fixture.db.clone();
    let recovery_db = fixture.db.clone();
    let assignment_id = accepted.assignment_id.clone();
    let authority_barrier = barrier.clone();
    let recovery_barrier = barrier.clone();
    let authority = tokio::spawn(async move {
        authority_barrier.wait().await;
        authority_db
            .claim_task_board_remote_executor_start_authority(
                &assignment_id,
                INSTANCE,
                STARTED_AT,
            )
            .await
    });
    let recovery = tokio::spawn(async move {
        recovery_barrier.wait().await;
        recovery_db
            .recover_task_board_remote_assignments(AFTER_EXPIRY)
            .await
    });
    barrier.wait().await;
    let authority = authority.await.expect("join authority").expect("authority result");
    let recovery = recovery.await.expect("join recovery").expect("recovery result");
    let durable = load_assignment(&fixture, &accepted.assignment_id).await;
    match authority {
        Some(authority) => {
            assert!(recovery.recovered.is_empty());
            assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Claimed);
            assert_eq!(
                durable.executor_start_authority_sha256.as_deref(),
                Some(authority.sha256.as_str())
            );
        }
        None => {
            assert_eq!(recovery.recovered.len(), 1);
            assert_eq!(durable.state, TaskBoardRemoteAssignmentState::Unknown);
            assert!(durable.executor_start_authority_sha256.is_none());
        }
    }
}

#[tokio::test]
async fn token_without_a_run_expires_only_after_its_exact_window() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            INSTANCE,
            STARTED_AT,
        )
        .await
        .expect("claim authority")
        .expect("authority");
    assert!(matches!(
        fixture
            .db
            .expire_task_board_remote_executor_start_without_run(
                &authority,
                "not yet expired",
                "2026-07-19T10:00:30Z",
            )
            .await
            .expect("reject early expiry"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert!(matches!(
        fixture
            .db
            .expire_task_board_remote_executor_start_without_run(
                &authority,
                "start window expired",
                AFTER_EXPIRY,
            )
            .await
            .expect("expire exact token"),
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Unknown
                && record.executor_start_authority_sha256.is_none()
    ));
    assert!(matches!(
        fixture
            .db
            .expire_task_board_remote_executor_start_without_run(
                &authority,
                "start window expired",
                AFTER_EXPIRY,
            )
            .await
            .expect("reject stale token replay"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
}

#[tokio::test]
async fn start_authority_digest_rejects_claim_evidence_tampering() {
    for (column, value) in [
        ("authenticated_principal", "different-principal"),
        ("claimed_at", "2026-07-19T10:00:11Z"),
        ("lease_expires_at", "2026-07-19T10:01:01Z"),
    ] {
        let fixture = executor_fixture(1).await;
        let accepted = claim_executor(&fixture).await;
        fixture
            .db
            .claim_task_board_remote_executor_start_authority(
                &accepted.assignment_id,
                INSTANCE,
                STARTED_AT,
            )
            .await
            .expect("claim authority")
            .expect("authority");
        let result = match column {
            "authenticated_principal" => query(
                "UPDATE task_board_remote_assignments SET authenticated_principal = ?2
                 WHERE assignment_id = ?1",
            )
            .bind(&accepted.assignment_id)
            .bind(value)
            .execute(fixture.db.pool())
            .await,
            "claimed_at" => query(
                "UPDATE task_board_remote_assignments SET claimed_at = ?2
                 WHERE assignment_id = ?1",
            )
            .bind(&accepted.assignment_id)
            .bind(value)
            .execute(fixture.db.pool())
            .await,
            "lease_expires_at" => query(
                "UPDATE task_board_remote_assignments SET lease_expires_at = ?2
                 WHERE assignment_id = ?1",
            )
            .bind(&accepted.assignment_id)
            .bind(value)
            .execute(fixture.db.pool())
            .await,
            _ => unreachable!("fixed test evidence column"),
        };
        if let Err(error) = result {
            assert_ne!(column, "lease_expires_at");
            assert!(
                error.to_string().contains("CHECK constraint failed"),
                "unexpected raw-write rejection: {error}"
            );
            continue;
        }
        let error = fixture
            .db
            .task_board_remote_assignment(&accepted.assignment_id)
            .await
            .expect_err("tampered authority must fail closed")
            .to_string();
        let expected = if column == "lease_expires_at" {
            "start authority contradicts"
        } else {
            "claim receipt contradicts"
        };
        assert!(error.contains(expected), "unexpected diagnostic: {error}");
    }
}

#[tokio::test]
async fn adoption_rejects_pre_token_and_mismatched_launch_evidence() {
    for mismatch in ["pre_token", "display_name"] {
        let fixture = executor_fixture(1).await;
        let accepted = claim_executor(&fixture).await;
        let authority = fixture
            .db
            .claim_task_board_remote_executor_start_authority(
                &accepted.assignment_id,
                INSTANCE,
                STARTED_AT,
            )
            .await
            .expect("claim authority")
            .expect("authority");
        let assignment = load_assignment(&fixture, &accepted.assignment_id).await;
        let run_at = if mismatch == "pre_token" { CLAIMED_AT } else { STARTED_AT };
        let (project_dir, permit) =
            persist_executor_run(&fixture, &assignment, &authority, STARTED_AT).await;
        if mismatch == "pre_token" {
            query("UPDATE codex_runs SET created_at = ?2 WHERE run_id = ?1")
                .bind(&authority.identity.run_id)
                .bind(CLAIMED_AT)
                .execute(fixture.db.pool())
                .await
                .expect("tamper pre-permit run chronology");
        }
        if mismatch == "display_name" {
            query("UPDATE codex_runs SET display_name = 'wrong launch' WHERE run_id = ?1")
                .bind(&authority.identity.run_id)
                .execute(fixture.db.pool())
                .await
                .expect("tamper launch request evidence");
        }
        assert!(matches!(
            fixture
                .db
                .adopt_task_board_remote_executor_start(
                    &permit,
                    Path::new(&project_dir),
                    run_at,
                )
                .await
                .expect("reject mismatched durable run"),
            TaskBoardRemoteMutationOutcome::Stale(ref record)
                if record.executor_start_authority_sha256.as_deref()
                    == Some(authority.sha256.as_str())
        ));
    }
}

#[tokio::test]
async fn a_successfully_stopped_invalid_run_clears_only_the_exact_token() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            INSTANCE,
            STARTED_AT,
        )
        .await
        .expect("claim authority")
        .expect("authority");
    let assignment = load_assignment(&fixture, &accepted.assignment_id).await;
    let (_, permit) =
        persist_executor_run(&fixture, &assignment, &authority, STARTED_AT).await;
    query("UPDATE codex_runs SET display_name = 'invalid launch evidence' WHERE run_id = ?1")
        .bind(&authority.identity.run_id)
        .execute(fixture.db.pool())
        .await
        .expect("persist invalid launch evidence");
    let snapshot = fixture
        .db
        .codex_run(&authority.identity.run_id)
        .await
        .expect("load invalid executor run")
        .expect("invalid executor run");
    let stop_authority = TaskBoardRemoteExecutorStopAuthority::Start(permit.clone());
    let pending = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &stop_authority,
            &snapshot,
            TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
            AFTER_EXPIRY,
        )
        .await
        .expect("claim stop-only authority")
        .expect("stop-only authority");
    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_start_authority(
                &accepted.assignment_id,
                INSTANCE,
                AFTER_EXPIRY,
            )
            .await
            .expect("stop-only start claim")
            .is_none()
    );
    assert!(matches!(
        fixture
            .db
            .adopt_task_board_remote_executor_start(
                &permit,
                Path::new(&snapshot.project_dir),
                STARTED_AT,
            )
            .await
            .expect("stop-only start adoption"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert!(matches!(
        fixture
            .db
            .settle_task_board_remote_executor_stop_pending(&pending, AFTER_EXPIRY)
            .await
            .expect("reject active stopped-run settlement"),
        TaskBoardRemoteMutationOutcome::Stale(ref record)
            if record.executor_start_authority_sha256.is_some()
                && record.executor_stop_pending.as_ref() == Some(&pending)
    ));
    query("UPDATE codex_runs SET status = 'cancelled' WHERE run_id = ?1")
        .bind(&authority.identity.run_id)
        .execute(fixture.db.pool())
        .await
        .expect("persist stopped deterministic run");
    assert!(matches!(
        fixture
            .db
            .settle_task_board_remote_executor_stop_pending(&pending, AFTER_EXPIRY)
            .await
            .expect("settle stopped start"),
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Unknown
                && record.executor_start_authority_sha256.is_none()
                && record.executor_stop_pending.is_none()
                && record.last_mutation_kind.as_deref() == Some("claim")
    ));
    assert!(matches!(
        fixture
            .db
            .settle_task_board_remote_executor_stop_pending(&pending, AFTER_EXPIRY)
            .await
            .expect("replay stopped start"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
}

async fn claim_executor(fixture: &ExecutorFixture) -> super::TaskBoardRemoteAssignmentRecord {
    let accepted = accept_executor(fixture, &fixture.request).await;
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(
                &claim_request(&fixture.request, &accepted),
                PRINCIPAL,
                CLAIMED_AT,
            )
            .await
            .expect("claim executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    accepted
}

async fn replay_start_authority(
    fixture: &ExecutorFixture,
    assignment_id: &str,
) -> TaskBoardRemoteExecutorStartAuthority {
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            assignment_id,
            INSTANCE,
            "2026-07-19T10:00:40Z",
        )
        .await
        .expect("claim start after renewal")
        .expect("renewed claim remains startable");
    let replay = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            assignment_id,
            INSTANCE,
            "2026-07-19T10:00:41Z",
        )
        .await
        .expect("replay start authority")
        .expect("authority remains durable");
    assert_eq!(replay, authority);
    authority
}

async fn load_assignment(
    fixture: &ExecutorFixture,
    assignment_id: &str,
) -> super::TaskBoardRemoteAssignmentRecord {
    fixture
        .db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load assignment")
        .expect("assignment")
}
