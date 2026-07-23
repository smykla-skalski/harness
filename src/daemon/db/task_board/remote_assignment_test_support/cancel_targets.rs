use super::{
    CLAIMED_AT, ControllerFixture, HOST, INSTANCE, LEASE_EXPIRES, NOW, claim_request, offer_request,
};
use crate::daemon::db::{
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome, TaskBoardRemoteOfferWindow,
    workflow_owner,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteClaimResponse, RemoteLease, RemoteOfferDisposition, RemoteOfferRequest,
    RemoteOfferResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionOwnership,
    TaskBoardWorkflowExecutionCas,
};

pub(crate) async fn seed_cancelable_controller_targets(fixture: &ControllerFixture, count: u32) {
    assert!(count > 0, "cancelable target fixture needs one target");
    offer_and_claim(
        fixture,
        &fixture.execution,
        &fixture.attempt,
        &fixture.request,
    )
    .await;
    for index in 1..count {
        let (execution, attempt, request) = candidate(fixture, index).await;
        offer_and_claim(fixture, &execution, &attempt, &request).await;
    }
}

async fn candidate(
    fixture: &ControllerFixture,
    index: u32,
) -> (
    crate::task_board::TaskBoardWorkflowExecutionRecord,
    crate::task_board::TaskBoardExecutionAttemptRecord,
    RemoteOfferRequest,
) {
    let suffix = format!("{index:03}");
    let item_id = format!("item-cancelable-{suffix}");
    let execution_id = format!("execution-cancelable-{suffix}");
    let mut item = crate::task_board::TaskBoardItem::new(
        item_id.clone(),
        format!("Cancelable remote {suffix}"),
        "Exercise cancel target truncation".into(),
        NOW.into(),
    );
    item.workflow_kind = fixture.execution.snapshot.workflow_kind;
    item.execution_repository = fixture.execution.snapshot.execution_repository.clone();
    let item = fixture
        .db
        .create_task_board_item(item)
        .await
        .expect("create cancelable target item");
    let mut execution = fixture.execution.clone();
    execution.execution_id.clone_from(&execution_id);
    execution.item_id = item_id;
    execution.snapshot.item_revision = item.item_revision;
    if let Some(context) = execution.snapshot.read_only_run_context.as_mut() {
        context.session_id = format!("session-cancelable-{suffix}");
        context.title = format!("Cancelable remote {suffix}");
    }
    execution.ownership = TaskBoardExecutionOwnership {
        host_id: None,
        fencing_epoch: 0,
        resources: std::collections::BTreeMap::from([(
            "admission_owner".into(),
            workflow_owner(&execution_id),
        )]),
    };
    execution.attempts.clear();
    fixture
        .db
        .create_or_load_task_board_workflow_execution(&execution)
        .await
        .expect("create cancelable target execution");
    let mut attempt = fixture.attempt.clone();
    attempt.execution_id.clone_from(&execution_id);
    attempt.idempotency_key = format!("cancelable-attempt-{suffix}");
    attempt.state = TaskBoardAttemptState::Preparing;
    fixture
        .db
        .create_task_board_execution_attempt(&attempt)
        .await
        .expect("create cancelable target attempt");
    let execution = fixture
        .db
        .task_board_workflow_execution(&execution_id)
        .await
        .expect("load cancelable target execution")
        .expect("cancelable target execution exists");
    let request = offer_request(
        &execution,
        &attempt,
        &format!("assignment-cancelable-{suffix}"),
        HOST,
        INSTANCE,
    );
    (execution, attempt, request)
}

async fn offer_and_claim(
    fixture: &ControllerFixture,
    execution: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    attempt: &crate::task_board::TaskBoardExecutionAttemptRecord,
    request: &RemoteOfferRequest,
) {
    let lease_id = format!("lease-{}", request.binding.assignment_id);
    assert!(matches!(
        fixture
            .db
            .offer_task_board_remote_assignment(
                &TaskBoardWorkflowExecutionCas::from(execution),
                &TaskBoardExecutionAttemptCas::from(attempt),
                request,
                HOST,
                TaskBoardRemoteOfferWindow::new(NOW, LEASE_EXPIRES, &request.deadline_at),
            )
            .await
            .expect("offer cancelable target"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    fixture
        .db
        .claim_task_board_remote_offer_io_authority(request, HOST, "2026-07-19T10:00:01Z")
        .await
        .expect("claim cancelable target offer authority")
        .expect("cancelable target offer remains active");
    let accepted = match fixture
        .db
        .record_task_board_remote_offer_response(
            &RemoteOfferResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                binding: request.binding.clone(),
                offer_request_sha256: request.request_sha256.clone(),
                disposition: RemoteOfferDisposition::Accepted,
                lease: Some(RemoteLease {
                    lease_id: lease_id.clone(),
                    expires_at: LEASE_EXPIRES.into(),
                }),
                rejection_code: None,
            },
            HOST,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("accept cancelable target offer")
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected accepted cancelable target, got {other:?}"),
    };
    let claim = claim_request(request, &accepted);
    fixture
        .db
        .claim_task_board_remote_claim_io_authority(&claim, HOST, "2026-07-19T10:00:05Z")
        .await
        .expect("claim cancelable target authority")
        .expect("cancelable target claim remains active");
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_assignment_claim(
                &claim,
                &RemoteClaimResponse {
                    schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                    binding: request.binding.clone(),
                    offer_request_sha256: request.request_sha256.clone(),
                    lease: RemoteLease {
                        lease_id,
                        expires_at: LEASE_EXPIRES.into(),
                    },
                    claimed_at: CLAIMED_AT.into(),
                },
                HOST,
                "2026-07-19T10:00:11Z",
            )
            .await
            .expect("persist cancelable target claim"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}
