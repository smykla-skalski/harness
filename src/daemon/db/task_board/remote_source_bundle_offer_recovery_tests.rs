use super::remote_assignment_inbox::PREDECESSOR_OFFER_NOT_RECEIVED;
use super::remote_assignment_test_support::{DEADLINE, HOST, LEASE_EXPIRES, NOW};
use super::remote_outbound_source_tests::snapshot_offer;
use super::{
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome, TaskBoardRemoteOperationTrustFence,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::tests::task_board::{
    PreparedRemoteOffer, prepare_remote_implementation_offer,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLease, RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    RemoteSourceBundleUploadRequest, RemoteSourceBundleUploadResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionHostAdvertisement,
    TaskBoardPhaseCapabilityProfile, TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
};

const SUCCESSOR_INSTANCE: &str = "instance-b";
const UPLOADED_AT: &str = "2026-07-19T10:00:01Z";
const OFFERED_AT: &str = "2026-07-19T10:00:03Z";
const SUCCESSOR_LEASE_EXPIRES: &str = "2026-07-19T10:01:03Z";

#[tokio::test]
async fn uploaded_source_and_absent_predecessor_offer_reassign_after_restart() {
    let setup = source_backed_predecessor("source-offer-absent").await;
    setup
        .prepared
        .db
        .claim_task_board_remote_offer_io_authority(&setup.offer, HOST, UPLOADED_AT)
        .await
        .expect("claim predecessor offer authority")
        .expect("predecessor offer remains active");
    let restarted = setup.prepared.db.reopen().await;
    let trust = successor_trust(&restarted).await;
    let rejection = absent_offer_response(&setup.offer);
    let parent = current_parent(&restarted, &setup.offer).await;
    let attempt = parent
        .attempts
        .iter()
        .find(|attempt| {
            attempt.action_key == setup.offer.binding.action_key
                && attempt.attempt == setup.offer.binding.attempt
        })
        .cloned()
        .expect("predecessor attempt remains current");
    let replacement = successor_offer(&setup.offer, &parent, &trust);

    let TaskBoardRemoteOfferOutcome::Created(created) = restarted
        .reassign_rejected_task_board_remote_source_bundle_offer(
            &TaskBoardWorkflowExecutionCas::from(&parent),
            &TaskBoardExecutionAttemptCas::from(&attempt),
            &setup.offer,
            &rejection,
            &replacement,
            HOST,
            &trust,
            OFFERED_AT,
            SUCCESSOR_LEASE_EXPIRES,
        )
        .await
        .expect("reassign exact uploaded bytes after authoritative offer absence")
    else {
        panic!("offer absence did not create the successor generation");
    };
    assert_eq!(created.assignment_id, replacement.binding.assignment_id);
    assert_reassigned_generation(&restarted, &setup, &replacement).await;

    let sequence = restarted
        .current_change_sequence()
        .await
        .expect("load reassignment sequence");
    assert!(matches!(
        restarted
            .reassign_rejected_task_board_remote_source_bundle_offer(
                &TaskBoardWorkflowExecutionCas::from(&parent),
                &TaskBoardExecutionAttemptCas::from(&attempt),
                &setup.offer,
                &rejection,
                &replacement,
                HOST,
                &trust,
                OFFERED_AT,
                SUCCESSOR_LEASE_EXPIRES,
            )
            .await
            .expect("replay exact source offer reassignment"),
        TaskBoardRemoteOfferOutcome::Replayed(record)
            if record.assignment_id == replacement.binding.assignment_id
    ));
    assert_eq!(
        restarted
            .current_change_sequence()
            .await
            .expect("load replay sequence"),
        sequence
    );
    assert_eq!(assignment_count(&restarted).await, 2);
}

#[tokio::test]
async fn uploaded_source_and_accepted_predecessor_offer_continue_after_restart() {
    let setup = source_backed_predecessor("source-offer-accepted").await;
    setup
        .prepared
        .db
        .claim_task_board_remote_offer_io_authority(&setup.offer, HOST, UPLOADED_AT)
        .await
        .expect("claim predecessor offer authority")
        .expect("predecessor offer remains active");
    let restarted = setup.prepared.db.reopen().await;
    let trust = successor_trust(&restarted).await;
    let accepted = accepted_offer_response(&setup.offer);

    let TaskBoardRemoteMutationOutcome::Updated(updated) = restarted
        .record_task_board_remote_predecessor_offer_acceptance(&accepted, HOST, &trust, OFFERED_AT)
        .await
        .expect("adopt immutable predecessor offer acceptance")
    else {
        panic!("predecessor acceptance did not update the original generation");
    };
    assert_eq!(updated.assignment_id, setup.offer.binding.assignment_id);
    assert_eq!(
        updated.target_host_instance_id.as_deref(),
        Some("instance-a")
    );
    assert_eq!(updated.lease_id.as_deref(), Some("lease-predecessor"));
    assert!(updated.controller_operation.is_none());
    assert_eq!(assignment_count(&restarted).await, 1);
    assert_parent_targets(&restarted, &setup.offer, &setup.offer.binding.assignment_id).await;

    let sequence = restarted
        .current_change_sequence()
        .await
        .expect("load predecessor acceptance sequence");
    assert!(matches!(
        restarted
            .record_task_board_remote_predecessor_offer_acceptance(
                &accepted,
                HOST,
                &trust,
                "2026-07-19T10:00:04Z",
            )
            .await
            .expect("replay immutable predecessor acceptance"),
        TaskBoardRemoteMutationOutcome::Replayed(record)
            if record.assignment_id == setup.offer.binding.assignment_id
    ));
    assert_eq!(
        restarted
            .current_change_sequence()
            .await
            .expect("load acceptance replay sequence"),
        sequence
    );
}

struct SourceBackedSetup {
    prepared: PreparedRemoteOffer,
    offer: RemoteOfferRequest,
    content: Vec<u8>,
}

async fn source_backed_predecessor(label: &str) -> SourceBackedSetup {
    let prepared = prepare_remote_implementation_offer(
        label,
        &format!("/tmp/{label}"),
        "1111111111111111111111111111111111111111",
    )
    .await;
    let (offer, content) = snapshot_offer(&prepared.offer);
    assert!(matches!(
        prepared
            .db
            .offer_task_board_remote_assignment_with_source(
                &TaskBoardWorkflowExecutionCas::from(&prepared.execution),
                &TaskBoardExecutionAttemptCas::from(&prepared.attempt),
                &offer,
                Some(&content),
                HOST,
                crate::daemon::db::TaskBoardRemoteOfferWindow::new(NOW, LEASE_EXPIRES, DEADLINE,),
            )
            .await
            .expect("persist source-backed predecessor"),
        TaskBoardRemoteOfferOutcome::Created(_)
    ));
    persist_upload_receipt(&prepared.db, &offer, &content).await;
    SourceBackedSetup {
        prepared,
        offer,
        content,
    }
}

async fn persist_upload_receipt(db: &AsyncDaemonDb, offer: &RemoteOfferRequest, content: &[u8]) {
    let request = RemoteSourceBundleUploadRequest::seal(offer.clone(), content)
        .expect("seal predecessor source upload");
    let trust = db
        .task_board_remote_operation_trust_fence(HOST)
        .await
        .expect("load predecessor upload trust");
    assert!(
        db.claim_task_board_remote_source_bundle_upload_io_authority_fenced(
            &request, HOST, &trust,
        )
        .await
        .expect("claim source upload authority")
    );
    let response = RemoteSourceBundleUploadResponse::seal(&request, UPLOADED_AT.into())
        .expect("seal source upload receipt");
    db.record_task_board_remote_source_bundle_upload_response(&request, &response, HOST)
        .await
        .expect("persist source upload receipt");
}

async fn successor_trust(db: &AsyncDaemonDb) -> TaskBoardRemoteOperationTrustFence {
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: HOST.into(),
            host_instance_id: SUCCESSOR_INSTANCE.into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec!["example/harness".into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite],
            capacity: 1,
            active_assignments: 0,
            heartbeat_at: "2026-07-19T10:00:02Z".into(),
        },
        "2026-07-19T10:00:02Z",
    )
    .await
    .expect("record successor executor observation");
    db.task_board_remote_operation_trust_fence(HOST)
        .await
        .expect("load successor source-recovery trust")
}

fn successor_offer(
    predecessor: &RemoteOfferRequest,
    parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> RemoteOfferRequest {
    let mut replacement = predecessor.clone();
    replacement.binding.assignment_id = format!("{}-successor", predecessor.binding.assignment_id);
    replacement.binding.host_instance_id = trust.observed_host_instance_id.clone();
    replacement.binding.fencing_epoch += 1;
    replacement.binding.execution_record_sha256 =
        TaskBoardWorkflowExecutionCas::from(parent).record_sha256;
    replacement.request_sha256.clear();
    replacement.seal().expect("seal successor source offer")
}

fn absent_offer_response(request: &RemoteOfferRequest) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Rejected,
        lease: None,
        rejection_code: Some(PREDECESSOR_OFFER_NOT_RECEIVED.into()),
    }
}

fn accepted_offer_response(request: &RemoteOfferRequest) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(RemoteLease {
            lease_id: "lease-predecessor".into(),
            expires_at: SUCCESSOR_LEASE_EXPIRES.into(),
        }),
        rejection_code: None,
    }
}

async fn current_parent(
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    db.task_board_workflow_execution(&offer.binding.execution_id)
        .await
        .expect("load current source parent")
        .expect("current source parent exists")
}

async fn assert_reassigned_generation(
    db: &AsyncDaemonDb,
    setup: &SourceBackedSetup,
    replacement: &RemoteOfferRequest,
) {
    let predecessor = db
        .task_board_remote_assignment(&setup.offer.binding.assignment_id)
        .await
        .expect("load predecessor after reassignment")
        .expect("predecessor retained");
    assert_eq!(
        predecessor.state,
        TaskBoardRemoteAssignmentState::Superseded
    );
    assert!(predecessor.controller_operation.is_none());
    let handoff: (String, String, i64) = sqlx::query_as(
        "SELECT controller_handoff_kind, controller_handoff_successor_assignment_id,
                controller_handoff_successor_fencing_epoch
         FROM task_board_remote_assignments WHERE assignment_id = ?1",
    )
    .bind(&predecessor.assignment_id)
    .fetch_one(db.pool())
    .await
    .expect("load exact predecessor handoff");
    assert_eq!(handoff.0, "remote_reassigned");
    assert_eq!(handoff.1, replacement.binding.assignment_id);
    assert_eq!(
        handoff.2,
        i64::try_from(replacement.binding.fencing_epoch).expect("successor epoch fits SQLite")
    );
    let upload = db
        .task_board_remote_outbound_source_upload(
            &replacement.binding.assignment_id,
            replacement.binding.fencing_epoch,
        )
        .await
        .expect("load successor outbound source")
        .expect("successor outbound source retained");
    assert_eq!(
        upload
            .validate()
            .expect("validate successor outbound bytes"),
        setup.content
    );
    let receipt = db
        .exact_task_board_remote_offer_receipt(&setup.offer, HOST)
        .await
        .expect("load predecessor rejection receipt")
        .expect("predecessor rejection receipt retained");
    assert_eq!(
        receipt.rejection_code.as_deref(),
        Some(PREDECESSOR_OFFER_NOT_RECEIVED)
    );
    assert_parent_targets(db, &setup.offer, &replacement.binding.assignment_id).await;
}

async fn assert_parent_targets(db: &AsyncDaemonDb, offer: &RemoteOfferRequest, target: &str) {
    let parent = current_parent(db, offer).await;
    let expected_target = format!("remote:{target}");
    assert_eq!(
        parent
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some(expected_target.as_str())
    );
}

async fn assignment_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_remote_assignments")
        .fetch_one(db.pool())
        .await
        .expect("count remote assignments")
}
