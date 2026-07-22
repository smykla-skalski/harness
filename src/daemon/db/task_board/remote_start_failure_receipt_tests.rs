use sqlx::query;

use super::super::remote_assignment_test_support::{
    CLAIMED_AT, INSTANCE, PRINCIPAL, STARTED_AT, accept_executor, claim_request, executor_fixture,
    persist_executor_run,
};
use super::super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartIoPermit,
    TaskBoardRemoteMutationOutcome,
};
use super::{TaskBoardRemoteExecutorStartFailureReceipt, canonical_json, receipt_digest};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease, RemoteStatusResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{TaskBoardFailureClass, TaskBoardRemoteAssignmentState};

#[tokio::test]
async fn failure_receipt_model_rejects_resealed_semantic_corruption() {
    for corruption in [
        Corruption::StatusBinding,
        Corruption::StatusSchema,
        Corruption::StatusDigest,
        Corruption::AuthorityDigest,
        Corruption::PermitDigest,
    ] {
        let pending = pending_permit(false).await;
        let failed = fail_without_run(&pending).await;
        let mut receipt = receipt_from(&failed);
        corrupt(&mut receipt, corruption);
        let json = canonical_json(&receipt).expect("serialize resealed receipt");
        let sha256 = receipt_digest(&receipt).expect("reseal outer receipt");
        query(
            "UPDATE task_board_remote_assignments
             SET executor_start_failure_receipt_json = ?2,
                 executor_start_failure_receipt_sha256 = ?3
             WHERE assignment_id = ?1",
        )
        .bind(&failed.assignment_id)
        .bind(json)
        .bind(sha256)
        .execute(pending.fixture.db.pool())
        .await
        .expect("persist raw semantic corruption with resealed outer digest");

        let _error = pending
            .fixture
            .db
            .task_board_remote_assignment(&failed.assignment_id)
            .await
            .expect_err("model must fail closed on resealed receipt corruption");
    }
}

#[tokio::test]
async fn no_run_failure_rejects_a_durable_deterministic_run_without_mutation() {
    let pending = pending_permit(true).await;
    let before = pending
        .fixture
        .db
        .task_board_remote_assignment(&pending.assignment_id)
        .await
        .expect("load before no-run failure")
        .expect("assignment exists");
    let error = pending
        .fixture
        .db
        .fail_task_board_remote_executor_start_without_run(
            &pending.permit,
            &failed_at_claimed_status(&before),
        )
        .await
        .expect_err("durable deterministic run invalidates no-run proof");
    assert!(error.to_string().contains("durable run"));

    let after = pending
        .fixture
        .db
        .task_board_remote_assignment(&pending.assignment_id)
        .await
        .expect("load after rejected no-run failure")
        .expect("assignment remains");
    assert_eq!(after.state, TaskBoardRemoteAssignmentState::Claimed);
    assert_eq!(
        after.executor_start_io_permit_sha256,
        before.executor_start_io_permit_sha256
    );
    assert_eq!(
        after.executor_start_io_permit_at,
        before.executor_start_io_permit_at
    );
    assert_eq!(
        after.executor_start_authority_sha256,
        before.executor_start_authority_sha256
    );
    assert_eq!(
        after.executor_start_authority_at,
        before.executor_start_authority_at
    );
    assert!(after.executor_start_failure_receipt_sha256.is_none());
}

#[derive(Clone, Copy, Debug)]
enum Corruption {
    StatusBinding,
    StatusSchema,
    StatusDigest,
    AuthorityDigest,
    PermitDigest,
}

struct PendingPermit {
    fixture: super::super::remote_assignment_test_support::ExecutorFixture,
    assignment_id: String,
    permit: TaskBoardRemoteExecutorStartIoPermit,
}

async fn pending_permit(keep_run: bool) -> PendingPermit {
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
        .expect("claimed assignment exists");
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            INSTANCE,
            STARTED_AT,
        )
        .await
        .expect("claim start authority")
        .expect("start remains authorized");
    let (_, permit) = persist_executor_run(&fixture, &claimed, &authority, STARTED_AT).await;
    if !keep_run {
        query("DELETE FROM codex_runs WHERE run_id = ?1")
            .bind(&permit.identity.run_id)
            .execute(fixture.db.pool())
            .await
            .expect("remove deterministic run for no-run proof");
    }
    PendingPermit {
        fixture,
        assignment_id: accepted.assignment_id,
        permit,
    }
}

async fn fail_without_run(pending: &PendingPermit) -> TaskBoardRemoteAssignmentRecord {
    let claimed = pending
        .fixture
        .db
        .task_board_remote_assignment(&pending.assignment_id)
        .await
        .expect("load permitted assignment")
        .expect("permitted assignment exists");
    match pending
        .fixture
        .db
        .fail_task_board_remote_executor_start_without_run(
            &pending.permit,
            &failed_at_claimed_status(&claimed),
        )
        .await
        .expect("seal proven no-run failure")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        outcome => panic!("expected settled no-run failure, got {outcome:?}"),
    }
}

fn receipt_from(
    record: &TaskBoardRemoteAssignmentRecord,
) -> TaskBoardRemoteExecutorStartFailureReceipt {
    serde_json::from_str(
        record
            .executor_start_failure_receipt_json
            .as_deref()
            .expect("failure receipt JSON"),
    )
    .expect("decode stored failure receipt")
}

fn corrupt(receipt: &mut TaskBoardRemoteExecutorStartFailureReceipt, corruption: Corruption) {
    match corruption {
        Corruption::StatusBinding => {
            receipt.status_response.binding.host_id = "other-host".into();
            reseal_status(receipt);
        }
        Corruption::StatusSchema => {
            receipt.status_response.schema_version += 1;
            reseal_status(receipt);
        }
        Corruption::StatusDigest => {
            receipt.status_response.status_sha256 = "f".repeat(64);
            receipt.status_sha256 = receipt.status_response.status_sha256.clone();
        }
        Corruption::AuthorityDigest => receipt.start_authority_sha256 = "f".repeat(64),
        Corruption::PermitDigest => receipt.start_io_permit_sha256 = "f".repeat(64),
    }
}

fn reseal_status(receipt: &mut TaskBoardRemoteExecutorStartFailureReceipt) {
    receipt.status_response = receipt
        .status_response
        .clone()
        .seal()
        .expect("reseal corrupted embedded status");
    receipt.status_sha256 = receipt.status_response.status_sha256.clone();
}

fn failed_at_claimed_status(record: &TaskBoardRemoteAssignmentRecord) -> RemoteStatusResponse {
    let offer = record.require_offer().expect("sealed offer");
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: record.lease_id.clone().expect("lease"),
            expires_at: record.lease_expires_at.clone().expect("lease expiry"),
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: record.claimed_at.clone(),
        started_at: None,
        workspace_ref: None,
        error_code: Some("remote_start_interrupted_without_run".into()),
        failure_class: Some(TaskBoardFailureClass::Transient),
        observed_at: STARTED_AT.into(),
    }
    .seal()
    .expect("seal Failed-at-Claimed status")
}
