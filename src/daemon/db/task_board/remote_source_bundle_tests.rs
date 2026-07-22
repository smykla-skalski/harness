use sha2::{Digest as _, Sha256};
use sqlx::query_scalar;

use super::TaskBoardRemoteOfferOutcome;
use super::remote_assignment_test_support::{
    INSTANCE, NOW, PRINCIPAL, REPOSITORY, accept_executor, executor_fixture,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteSourceBundleAbandonRequest,
    RemoteSourceBundleUploadRequest, RemoteSourceMaterial, test_codex_launch,
};
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardPhaseCapabilityProfile, TaskBoardWorkflowKind,
};

const BASE: &str = "1111111111111111111111111111111111111111";
const RESULT: &str = "2222222222222222222222222222222222222222";
const SOURCE_REVISION: &str = "3333333333333333333333333333333333333333";

#[tokio::test]
async fn prior_phase_offer_requires_durable_exact_bundle_and_replays_after_restart() {
    let fixture = executor_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    assert!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(&offer, PRINCIPAL, INSTANCE, NOW)
            .await
            .is_err()
    );
    assert_eq!(assignment_count(&fixture.db).await, 0);

    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), &content)
        .expect("seal source bundle upload");
    let first = fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("persist source bundle");
    let reopened = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("reopen executor db after lost upload response");
    let replay = reopened
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, "restarted-instance", NOW)
        .await
        .expect("replay source bundle after lost response and executor restart");
    assert_eq!(replay, first);

    let assignment = accept_executor(&fixture, &offer).await;
    let stored = reopened
        .task_board_remote_source_bundle(&assignment)
        .await
        .expect("load source bundle after restart")
        .expect("source bundle exists");
    assert_eq!(stored.content.as_deref(), Some(content.as_slice()));
    assert_eq!(stored.response, first.response);
}

#[tokio::test]
async fn source_bundle_tamper_or_conflict_never_creates_an_assignment() {
    let fixture = executor_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), &content)
        .expect("seal source bundle upload");
    fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("persist source bundle");

    assert!(
        fixture
            .db
            .store_task_board_remote_source_bundle(&upload, "other-principal", INSTANCE, NOW)
            .await
            .is_err()
    );
    let mut wrong_epoch = offer.clone();
    wrong_epoch.binding.fencing_epoch += 1;
    wrong_epoch.request_sha256.clear();
    let wrong_epoch = wrong_epoch.seal().expect("seal conflicting epoch");
    let wrong_epoch = RemoteSourceBundleUploadRequest::seal(wrong_epoch, &content)
        .expect("seal conflicting epoch upload");
    assert!(
        fixture
            .db
            .store_task_board_remote_source_bundle(&wrong_epoch, PRINCIPAL, INSTANCE, NOW)
            .await
            .is_err()
    );

    let mut wrong_assignment = upload.clone();
    wrong_assignment
        .offer
        .binding
        .assignment_id
        .push_str("-other");
    assert!(wrong_assignment.validate().is_err());

    let mut wrong_digest = upload.clone();
    change_digest(&mut wrong_digest.request_sha256);
    assert!(wrong_digest.validate().is_err());

    let mut tampered = offer;
    let RemoteSourceMaterial::PriorPhaseBundle { revision, .. } = &mut tampered.source else {
        unreachable!("bundle source")
    };
    *revision = "3333333333333333333333333333333333333333".into();
    tampered.request_sha256.clear();
    // Reseal so the digest is valid; the tampered revision now contradicts the
    // advertised ref and binding base, which the upload seal must reject.
    let tampered = tampered.seal().expect("reseal tampered prior-phase offer");
    assert!(RemoteSourceBundleUploadRequest::seal(tampered, &content).is_err());
    assert_eq!(assignment_count(&fixture.db).await, 0);
    assert_eq!(source_bundle_count(&fixture.db).await, 1);
}

#[tokio::test]
async fn source_abandonment_reloads_exact_authority_and_replays_after_restart() {
    let fixture = executor_fixture(1).await;
    let (offer, content) = snapshot_offer(&fixture.request);
    let upload =
        RemoteSourceBundleUploadRequest::seal(offer, &content).expect("seal absent source upload");
    let verification = fixture
        .db
        .verify_task_board_remote_source_bundle_receipt(
            &upload,
            PRINCIPAL,
            "instance-b",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("verify authoritative source absence");
    assert!(verification.receipt.is_none());
    let request = RemoteSourceBundleAbandonRequest::seal(&upload, verification.clone())
        .expect("seal exact abandonment request");
    let first = fixture
        .db
        .abandon_task_board_remote_source_bundle(
            &request,
            PRINCIPAL,
            "instance-b",
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("persist source abandonment");
    fixture.db.pool().close().await;

    let restarted = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("restart after source abandonment response loss");
    let stored = restarted
        .exact_task_board_remote_source_bundle_abandonment(&upload, PRINCIPAL)
        .await
        .expect("load exact source abandonment")
        .expect("source abandonment retained");
    assert_eq!(stored.request, request);
    assert_eq!(stored.response, first.response);
    let replayed_verification = restarted
        .verify_task_board_remote_source_bundle_receipt(
            &upload,
            PRINCIPAL,
            "instance-b",
            "2026-07-19T10:00:03Z",
        )
        .await
        .expect("replay immutable source absence verification");
    assert_eq!(replayed_verification, verification);
    let replay_request = RemoteSourceBundleAbandonRequest::seal(&upload, replayed_verification)
        .expect("reseal exact abandonment request");
    assert_eq!(replay_request, request);
    let replay = restarted
        .abandon_task_board_remote_source_bundle(
            &replay_request,
            PRINCIPAL,
            "instance-b",
            "2026-07-19T10:00:04Z",
        )
        .await
        .expect("replay immutable source abandonment");
    assert_eq!(replay.response, first.response);
}

#[tokio::test]
async fn repository_snapshot_upload_replays_and_gates_offer_admission() {
    let fixture = executor_fixture(1).await;
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.capabilities =
        vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite];
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("enable implementation capability");
    let (offer, content) = snapshot_offer(&fixture.request);
    assert!(
        fixture
            .db
            .accept_task_board_remote_assignment_offer(&offer, PRINCIPAL, INSTANCE, NOW)
            .await
            .is_err()
    );

    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), &content)
        .expect("seal repository snapshot upload");
    let first = fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("store repository snapshot");
    let reopened = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("reopen executor with repository snapshot");
    let replay = reopened
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, "instance-b", NOW)
        .await
        .expect("replay immutable repository snapshot receipt");
    assert_eq!(replay, first);
    let TaskBoardRemoteOfferOutcome::Created(assignment) = reopened
        .accept_task_board_remote_assignment_offer(&offer, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("accept uploaded repository snapshot")
    else {
        panic!("repository snapshot offer was not created");
    };

    let corrupt = sqlx::query(
        "UPDATE task_board_remote_source_bundles
         SET source_kind = 'prior_phase_bundle'
         WHERE assignment_id = ?1",
    )
    .bind(&offer.binding.assignment_id)
    .execute(reopened.pool())
    .await;
    assert!(corrupt.is_err(), "kind-specific SQL shape must fail closed");

    sqlx::query(
        "UPDATE task_board_remote_source_bundles
         SET content = X'', content_pruned_at = '2026-07-27T10:00:00Z'
         WHERE assignment_id = ?1",
    )
    .bind(&offer.binding.assignment_id)
    .execute(reopened.pool())
    .await
    .expect("model pruned repository snapshot bytes");
    let mut connection = reopened.pool().acquire().await.expect("acquire raw db");
    sqlx::query("PRAGMA ignore_check_constraints = ON")
        .execute(&mut *connection)
        .await
        .expect("allow raw corruption");
    sqlx::query(
        "UPDATE task_board_remote_source_bundles
         SET advertised_ref = 'refs/harness/task-board/sources/ffffffffffffffffffffffffffffffffffffffff'
         WHERE assignment_id = ?1",
    )
    .bind(&offer.binding.assignment_id)
    .execute(&mut *connection)
    .await
    .expect("corrupt pruned source provenance");
    sqlx::query("PRAGMA ignore_check_constraints = OFF")
        .execute(&mut *connection)
        .await
        .expect("restore strict checks");
    drop(connection);
    assert!(
        reopened
            .task_board_remote_source_bundle(&assignment)
            .await
            .expect_err("pruned provenance corruption must fail closed")
            .to_string()
            .contains("contradict")
    );
}

#[tokio::test]
async fn lost_offer_response_replays_acceptance_after_restart_and_forbids_reassignment() {
    let fixture = executor_fixture(1).await;
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.capabilities =
        vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite];
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("enable implementation capability");
    let (offer, content) = snapshot_offer(&fixture.request);
    let upload =
        RemoteSourceBundleUploadRequest::seal(offer.clone(), &content).expect("seal source upload");
    fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("store source before offer");
    let TaskBoardRemoteOfferOutcome::Created(first) = fixture
        .db
        .accept_task_board_remote_assignment_offer(&offer, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("persist accepted offer before response loss")
    else {
        panic!("first offer was not accepted");
    };
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("restart after lost accepted response");
    let TaskBoardRemoteOfferOutcome::AcceptedReplay(replayed) = restarted
        .accept_task_board_remote_assignment_offer(
            &offer,
            PRINCIPAL,
            "restarted-instance",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("replay exact accepted offer after restart")
    else {
        panic!("accepted offer did not byte-replay");
    };
    assert_eq!(replayed.initial_lease_id, first.lease_id);
    assert_eq!(replayed.initial_lease_expires_at, first.lease_expires_at);
    let verification = restarted
        .verify_task_board_remote_source_bundle_receipt(
            &upload,
            PRINCIPAL,
            "restarted-instance",
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("verify source receipt after accepted replay");
    assert!(verification.receipt.is_some());
    assert!(
        RemoteSourceBundleAbandonRequest::seal(&upload, verification).is_err(),
        "accepted predecessor must never produce absence authority"
    );
}

#[tokio::test]
async fn rejected_orphan_source_prunes_bytes_but_replays_compact_receipt_after_restart() {
    let fixture = executor_fixture(1).await;
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.capabilities =
        vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite];
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("enable implementation capability");
    let (offer, content) = snapshot_offer(&fixture.request);
    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), &content)
        .expect("seal orphan source upload");
    let first = fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("store source before executor restart");
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("restart executor before old-instance offer");
    let rejected = restarted
        .accept_task_board_remote_assignment_offer(
            &offer,
            PRINCIPAL,
            "instance-b",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("durably reject old-instance offer");
    let TaskBoardRemoteOfferOutcome::Rejected(rejected) = rejected else {
        panic!("old-instance offer did not persist a rejection tombstone");
    };
    assert_eq!(
        rejected.rejection_code.as_deref(),
        Some(super::remote_assignment_inbox::PREDECESSOR_OFFER_NOT_RECEIVED)
    );
    assert_eq!(assignment_count(&restarted).await, 0);
    assert_eq!(
        restarted
            .prune_task_board_remote_execution_evidence("2026-07-26T10:00:00Z")
            .await
            .expect("retain orphan source inside window")
            .source_bundle_contents,
        0
    );
    assert_eq!(
        restarted
            .prune_task_board_remote_execution_evidence("2026-07-27T10:00:00Z")
            .await
            .expect("prune aged rejected orphan source")
            .source_bundle_contents,
        1
    );
    let replay = restarted
        .store_task_board_remote_source_bundle(
            &upload,
            PRINCIPAL,
            "instance-b",
            "2026-07-27T10:00:01Z",
        )
        .await
        .expect("replay compact upload receipt after pruning");
    assert_eq!(replay.response, first.response);
    assert!(replay.content.is_none());
    assert_eq!(assignment_count(&restarted).await, 0);
}

fn bundle_offer(
    template: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
) -> (
    crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    Vec<u8>,
) {
    let content = b"durable prior phase bundle bytes".to_vec();
    let bundle = RemoteArtifactEntry {
        relative_path: "source/prior-phase.bundle".into(),
        sha256: hex::encode(Sha256::digest(&content)),
        size_bytes: u64::try_from(content.len()).expect("bundle size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = template.clone();
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    // A prior-phase attempt starts from the prior phase's sealed head, so the
    // binding base must be the bundle's advertised result revision.
    offer.binding.base_revision = RESULT.into();
    offer.source =
        RemoteSourceMaterial::prior_phase_bundle(REPOSITORY, BASE, RESULT, bundle.clone());
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![bundle],
    };
    offer.request_sha256.clear();
    (offer.seal().expect("seal bundle offer"), content)
}

fn snapshot_offer(
    template: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
) -> (
    crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    Vec<u8>,
) {
    let content = b"self-contained repository snapshot bundle".to_vec();
    let bundle = RemoteArtifactEntry {
        relative_path: "source/repository.bundle".into(),
        sha256: hex::encode(Sha256::digest(&content)),
        size_bytes: u64::try_from(content.len()).expect("snapshot size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = template.clone();
    offer.binding.phase = TaskBoardExecutionPhase::Implementation;
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    offer.binding.action_key = "implementation:1".into();
    offer.binding.base_revision = SOURCE_REVISION.into();
    offer.binding.expected_head_revision = None;
    offer.launch = test_codex_launch(
        TaskBoardExecutionPhase::Implementation,
        &offer.binding.execution_id,
        &offer.binding.action_key,
        "Implement the frozen task plan.",
    );
    offer.source = RemoteSourceMaterial::repository_snapshot_bundle(
        REPOSITORY,
        SOURCE_REVISION,
        bundle.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![bundle],
    };
    offer.request_sha256.clear();
    (
        offer.seal().expect("seal repository snapshot offer"),
        content,
    )
}

async fn assignment_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_assignments")
        .fetch_one(db.pool())
        .await
        .expect("count assignments")
}

async fn source_bundle_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_source_bundles")
        .fetch_one(db.pool())
        .await
        .expect("count source bundles")
}

fn change_digest(value: &mut String) {
    let replacement = if value.starts_with('0') { "1" } else { "0" };
    value.replace_range(..1, replacement);
}
