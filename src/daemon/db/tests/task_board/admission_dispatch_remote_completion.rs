use super::completion_evidence_tests::{
    accepted_offer, intent_status, remote_status, remote_status_request,
};
use super::remote_start_tests::prepare_remote_offer_with_policy;
use super::*;
use crate::daemon::db::task_board::remote_assignment_test_support::claim_request;
use crate::daemon::db::task_board::TaskBoardRemoteOperationKind;
use crate::daemon::task_board_remote_transport::wire::RemoteAssignmentWireState;
use crate::task_board::TaskBoardWorkflowExecutionCas;

#[tokio::test]
async fn remote_claim_keeps_finite_admission_reserved_until_exact_start_evidence() {
    let prepared = claimed_remote_without_start("admission-remote-start").await;
    let status_request = remote_status_request(&prepared.offer);

    assert_claim_does_not_commit(&prepared).await;
    prepared
        .db
        .record_task_board_remote_assignment_status(
            &status_request,
            &remote_status(
                &prepared.offer,
                RemoteAssignmentWireState::Running,
                true,
            ),
            "executor-a",
        )
        .await
        .expect("record exact start evidence");
    assert_exact_start_commits_once(&prepared).await;
}

#[tokio::test]
async fn workflow_prepared_remote_claim_blocks_public_item_mutation() {
    let prepared = claimed_remote_without_start("admission-remote-mutation").await;
    let error = prepared
        .db
        .update_task_board_item(&prepared.execution.item_id, |item| {
            item.title = "Forbidden after remote claim".into();
            Ok(true)
        })
        .await
        .expect_err("workflow-prepared remote claim must fence public mutation");
    assert!(
        error
            .to_string()
            .contains("cannot change while its workflow side effect is claimed")
    );
}

async fn claimed_remote_without_start(label: &str) -> PreparedRemoteOffer {
    let prepared = prepare_remote_offer_with_policy(label, true).await;
    prepared
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&prepared.execution),
            &crate::task_board::TaskBoardExecutionAttemptCas::from(&prepared.attempt),
            &prepared.offer,
            "executor-a",
            "2026-07-19T10:00:00Z",
            "2026-07-19T10:01:00Z",
            "2026-07-19T10:10:00Z",
        )
        .await
        .expect("offer remote assignment");
    prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer I/O authority")
        .expect("remote offer stays active");
    prepared
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&prepared.offer),
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("record accepted offer");
    // Grant the claim I/O authority (response treated as lost) so the claim-only status
    // reconstructs the claim and promotes the assignment.
    let accepted = prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load accepted assignment")
        .expect("accepted assignment");
    let claim = claim_request(&prepared.offer, &accepted);
    prepared
        .db
        .claim_task_board_remote_claim_io_authority(&claim, "executor-a", "2026-07-19T10:00:01Z")
        .await
        .expect("claim remote claim authority")
        .expect("claim remains active");
    prepared
        .db
        .complete_task_board_remote_operation_trust(
            &prepared.offer.binding.assignment_id,
            TaskBoardRemoteOperationKind::Claim,
            &claim.request_sha256,
        )
        .await
        .expect("release completed claim transport trust");
    prepared
        .db
        .record_task_board_remote_assignment_status(
            &remote_status_request(&prepared.offer),
            &remote_status(
                &prepared.offer,
                RemoteAssignmentWireState::Claimed,
                false,
            ),
            "executor-a",
        )
        .await
        .expect("record claim-only evidence");
    prepared
}

async fn assert_claim_does_not_commit(prepared: &PreparedRemoteOffer) {
    let error = prepared
        .db
        .complete_task_board_workflow_dispatch_start(&prepared.execution_id)
        .await
        .expect_err("claim alone must not commit finite admission");
    assert!(
        error
            .to_string()
            .contains("has not durably confirmed its exact start"),
        "{error}"
    );
    assert_eq!(
        intent_status(&prepared.db, &prepared.intent).await,
        "workflow_prepared"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
        "reserved"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "reserved"
    );
}

async fn assert_exact_start_commits_once(prepared: &PreparedRemoteOffer) {
    assert!(
        !prepared
            .db
            .complete_task_board_workflow_dispatch_start(&prepared.execution_id)
            .await
            .expect("exact status already committed finite admission")
    );
    assert_eq!(intent_status(&prepared.db, &prepared.intent).await, "completed");
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
        "committed"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "committed"
    );
}
