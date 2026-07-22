//! Regression coverage for immutable executor start receipts and owner leases.

use std::path::Path;

use sqlx::query;

use super::remote_assignment_test_support::*;
use super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartIoPermit,
    TaskBoardRemoteMutationOutcome,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLeaseRenewRequest, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

const OWNER_REPLAY_AT: &str = "2026-07-19T10:00:40Z";
const OWNER_TAKEOVER_AT: &str = "2026-07-19T10:00:51Z";

struct AdoptedExecutor {
    fixture: ExecutorFixture,
    authority: TaskBoardRemoteExecutorStartIoPermit,
    project_dir: String,
    record: TaskBoardRemoteAssignmentRecord,
}

#[tokio::test]
async fn start_receipt_survives_lease_rotation_and_owner_takeover() {
    let adopted = adopted_executor().await;
    let receipt = adopted.record.start_receipt.clone().expect("start receipt");
    let initial_owner = adopted
        .record
        .executor_lifecycle_owner
        .clone()
        .expect("initial lifecycle owner");
    let renewal = RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: adopted.fixture.request.binding.clone(),
        lease_id: adopted.record.lease_id.clone().expect("initial lease"),
        offer_request_sha256: adopted.fixture.request.request_sha256.clone(),
        extend_seconds: 60,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal renewal");
    let renewed = adopted
        .fixture
        .db
        .renew_task_board_remote_assignment_lease(
            &renewal,
            PRINCIPAL,
            "2026-07-19T10:00:30Z",
        )
        .await
        .expect("renew after start");
    assert!(matches!(
        renewed,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.start_receipt.as_ref() == Some(&receipt)
                && record.lease_id.as_deref() != Some(renewal.lease_id.as_str())
    ));

    assert!(matches!(
        adopted
            .fixture
            .db
            .adopt_task_board_remote_executor_start(
                &adopted.authority,
                Path::new(&adopted.project_dir),
                STARTED_AT,
            )
            .await
            .expect("replay start after renewal"),
        TaskBoardRemoteMutationOutcome::Replayed(ref record)
            if record.start_receipt.as_ref() == Some(&receipt)
    ));
    let same_owner = adopted
        .fixture
        .db
        .claim_task_board_remote_executor_lifecycle_owner(
            &adopted.record.assignment_id,
            INSTANCE,
            OWNER_REPLAY_AT,
        )
        .await
        .expect("replay same live owner")
        .expect("same owner remains live");
    assert_eq!(same_owner, initial_owner);

    let successor = adopted
        .fixture
        .db
        .claim_task_board_remote_executor_lifecycle_owner(
            &adopted.record.assignment_id,
            "instance-b",
            OWNER_TAKEOVER_AT,
        )
        .await
        .expect("take over expired owner")
        .expect("expired owner transfers");
    assert_eq!(successor.owner_epoch, initial_owner.owner_epoch + 1);
    assert_ne!(successor.sha256, initial_owner.sha256);
    assert!(matches!(
        adopted
            .fixture
            .db
            .adopt_task_board_remote_executor_start(
                &adopted.authority,
                Path::new(&adopted.project_dir),
                STARTED_AT,
            )
            .await
            .expect("replay start after owner transfer"),
        TaskBoardRemoteMutationOutcome::Replayed(ref record)
            if record.start_receipt.as_ref() == Some(&receipt)
                && record.executor_lifecycle_owner.as_ref() == Some(&successor)
    ));
}

#[tokio::test]
async fn start_adoption_rejects_wrong_durable_session_or_worktree() {
    for (field, value) in [
        ("session_id", "different-session"),
        ("worktree_path", "/tmp/different-worktree"),
    ] {
        let prepared = prepared_executor().await;
        query(
            "UPDATE sessions SET state_json = json_set(state_json, ?2, ?3)
             WHERE session_id = ?1",
        )
        .bind(&prepared.authority.identity.session_id)
        .bind(format!("$.{field}"))
        .bind(value)
        .execute(prepared.fixture.db.pool())
        .await
        .expect("corrupt durable session evidence");
        assert!(matches!(
            prepared
                .fixture
                .db
                .adopt_task_board_remote_executor_start(
                    &prepared.authority,
                    Path::new(&prepared.project_dir),
                    STARTED_AT,
                )
                .await
                .expect("reject mismatched durable session"),
            TaskBoardRemoteMutationOutcome::Stale(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Claimed
                    && record.executor_start_authority_sha256.is_some()
                    && record.start_receipt.is_none()
        ));
    }
}

#[tokio::test]
async fn schema_rejects_partial_start_receipt_and_owner_evidence() {
    let statements: [&'static str; 2] = [
        "UPDATE task_board_remote_assignments
         SET executor_start_receipt_sha256 = NULL WHERE assignment_id = ?1",
        "UPDATE task_board_remote_assignments
         SET executor_lifecycle_owner_epoch = NULL WHERE assignment_id = ?1",
    ];
    for statement in statements {
        let adopted = adopted_executor().await;
        let error = query(statement)
            .bind(&adopted.record.assignment_id)
            .execute(adopted.fixture.db.pool())
            .await
            .expect_err("partial start evidence must violate the strict shape");
        assert!(error.to_string().contains("CHECK constraint failed"));
        assert!(
            adopted
                .fixture
                .db
                .task_board_remote_assignment(&adopted.record.assignment_id)
                .await
                .expect("load unchanged assignment")
                .is_some()
        );
    }
}

#[tokio::test]
async fn model_rejects_tampered_start_receipt_and_owner_digests() {
    let receipt_tamper = adopted_executor().await;
    query(
        "UPDATE task_board_remote_assignments
         SET executor_start_receipt_json = json_set(
             executor_start_receipt_json, '$.start_authority_sha256', ?2
         ) WHERE assignment_id = ?1",
    )
    .bind(&receipt_tamper.record.assignment_id)
    .bind("f".repeat(64))
    .execute(receipt_tamper.fixture.db.pool())
    .await
    .expect("persist self-consistent-shape receipt tamper");
    let receipt_error = receipt_tamper
        .fixture
        .db
        .task_board_remote_assignment(&receipt_tamper.record.assignment_id)
        .await
        .expect_err("receipt digest must reject semantic tampering");
    assert!(receipt_error.to_string().contains("start receipt"));

    let owner_tamper = adopted_executor().await;
    query(
        "UPDATE task_board_remote_assignments
         SET executor_lifecycle_owner_sha256 = ?2 WHERE assignment_id = ?1",
    )
    .bind(&owner_tamper.record.assignment_id)
    .bind("f".repeat(64))
    .execute(owner_tamper.fixture.db.pool())
    .await
    .expect("persist shape-valid owner tamper");
    let owner_error = owner_tamper
        .fixture
        .db
        .task_board_remote_assignment(&owner_tamper.record.assignment_id)
        .await
        .expect_err("owner digest must reject semantic tampering");
    assert!(owner_error.to_string().contains("lifecycle owner"));
}

async fn adopted_executor() -> AdoptedExecutor {
    let prepared = prepared_executor().await;
    let outcome = prepared
        .fixture
        .db
        .adopt_task_board_remote_executor_start(
            &prepared.authority,
            Path::new(&prepared.project_dir),
            STARTED_AT,
        )
        .await
        .expect("adopt exact remote start");
    let TaskBoardRemoteMutationOutcome::Updated(record) = outcome else {
        panic!("expected updated start, got {outcome:?}");
    };
    AdoptedExecutor {
        fixture: prepared.fixture,
        authority: prepared.authority,
        project_dir: prepared.project_dir,
        record,
    }
}

async fn prepared_executor() -> AdoptedExecutor {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    let claim = claim_request(&fixture.request, &accepted);
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
            .await
            .expect("claim executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    let claimed = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load claimed assignment")
        .expect("claimed assignment");
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &claimed.assignment_id,
            INSTANCE,
            STARTED_AT,
        )
        .await
        .expect("claim executor start authority")
        .expect("executor remains startable");
    let (project_dir, permit) =
        persist_executor_run(&fixture, &claimed, &authority, STARTED_AT).await;
    AdoptedExecutor {
        fixture,
        authority: permit,
        project_dir,
        record: claimed,
    }
}
