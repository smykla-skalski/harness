use sha2::{Digest as _, Sha256};

use super::TaskBoardRemoteOfferOutcome;
use super::remote_assignment_test_support::{
    HOST, INSTANCE, NOW, PRINCIPAL, REPOSITORY, SOURCE_REVISION, detached_offer, executor_fixture,
};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteOfferRequest,
    RemoteSourceBundleAbandonRequest, RemoteSourceBundleUploadRequest, RemoteSourceMaterial,
    test_codex_launch,
};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

// The prior phase's own base; the bundle result revision must equal the current
// binding's base_revision (SOURCE_REVISION) or the upload seal rejects it.
const PRIOR_BASE: &str = "3333333333333333333333333333333333333333";

#[tokio::test]
async fn source_upload_rejects_archival_identity_collision_without_bytes() {
    let fixture = super::remote_assignment_test_support::executor_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    // A frozen legacy assignment already owns this offer's idempotency key. The
    // upload persists immutable bytes before any assignment exists, so without
    // the archival fence a new assignment id could strand bytes forever.
    insert_archival_assignment(
        &fixture.db,
        "legacy-archived-upload",
        &offer.binding.idempotency_key,
    )
    .await;
    let before = sequence(&fixture.db).await;

    let upload =
        RemoteSourceBundleUploadRequest::seal(offer, &content).expect("seal source bundle upload");
    let error = fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect_err("archival identity collision must fail closed on source upload")
        .to_string();

    assert!(
        error.contains("collides with archived legacy assignment 'legacy-archived-upload'"),
        "unexpected error: {error}"
    );
    assert_eq!(
        source_bundle_count(&fixture.db).await,
        0,
        "a refused source upload must persist no immutable bytes"
    );
    assert_eq!(
        sequence(&fixture.db).await,
        before,
        "a refused source upload must not bump the change sequence"
    );
}

#[tokio::test]
async fn source_upload_rejects_each_live_assignment_identity_in_isolation() {
    // B (bundle_offer of the fixture request) owns execution-detached /
    // review:reviewer / attempt 1 / attempt-key-1 / epoch 1. Each rival collides
    // on exactly one identity so removing any clause of the assignment fence
    // regresses exactly one case.
    // (label, execution_id, action_key, attempt, idempotency_key, fencing_epoch).
    let cases: [(&str, &str, &str, u32, &str, u64); 3] = [
        (
            "idempotency",
            "execution-rival",
            "review:rival",
            9,
            "attempt-key-1",
            9,
        ),
        (
            "exact-attempt",
            "execution-detached",
            "review:reviewer",
            1,
            "rival-key-2",
            9,
        ),
        (
            "execution-epoch",
            "execution-detached",
            "review:rival",
            9,
            "rival-key-3",
            1,
        ),
    ];
    for (label, execution_id, action_key, attempt, idempotency_key, fencing_epoch) in cases {
        let fixture = executor_fixture(1).await;
        let (offer, content) = bundle_offer(&fixture.request);
        let rival = rival_offer(
            &format!("assignment-{label}"),
            execution_id,
            action_key,
            attempt,
            idempotency_key,
            fencing_epoch,
        );
        insert_live_assignment(&fixture.db, &rival).await;
        let before = sequence(&fixture.db).await;

        let upload = RemoteSourceBundleUploadRequest::seal(offer, &content).expect("seal upload");
        let error = fixture
            .db
            .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
            .await
            .expect_err("a live-assignment collision must fail closed on source upload")
            .to_string();

        assert!(
            error.contains("conflicts with a live assignment or receipt"),
            "[{label}] unexpected error: {error}"
        );
        assert_eq!(
            source_bundle_count(&fixture.db).await,
            0,
            "[{label}] a refused upload must persist no bytes"
        );
        assert_eq!(
            sequence(&fixture.db).await,
            before,
            "[{label}] a refused upload must not bump the change sequence"
        );
    }
}

#[tokio::test]
async fn source_upload_rejects_a_rejected_offer_receipt_collision_without_bytes() {
    let fixture = executor_fixture(1).await;
    let (offer, content) = bundle_offer(&fixture.request);
    // A durable rejected offer receipt (no live assignment) already owns B's
    // identity; only the receipt lookup can see it, so dropping that lookup would
    // regress here while the assignment cases stay green.
    let rival = detached_offer("assignment-rejected-rival", &offer.binding.idempotency_key);
    let rejected = fixture
        .db
        .accept_task_board_remote_assignment_offer(&rival, PRINCIPAL, "wrong-instance-b", NOW)
        .await
        .expect("rival offer is durably rejected");
    assert!(
        matches!(rejected, TaskBoardRemoteOfferOutcome::Rejected(_)),
        "expected a durable rejection, got {rejected:?}"
    );
    let before = sequence(&fixture.db).await;

    let upload = RemoteSourceBundleUploadRequest::seal(offer, &content).expect("seal upload");
    let error = fixture
        .db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect_err("a rejected-receipt collision must fail closed on source upload")
        .to_string();

    assert!(
        error.contains("conflicts with a live assignment or receipt"),
        "unexpected error: {error}"
    );
    assert_eq!(
        source_bundle_count(&fixture.db).await,
        0,
        "no bytes on a refused upload"
    );
    assert_eq!(
        sequence(&fixture.db).await,
        before,
        "no sequence bump on a refused upload"
    );
}

#[tokio::test]
async fn abandoned_generation_fences_aliased_upload_and_accept_across_restart() {
    let fixture = executor_fixture(1).await;
    // Abandon generation A (execution-detached / epoch 1) with its source
    // verified absent.
    let (offer_a, content_a) = snapshot_offer(&fixture.request);
    let upload_a =
        RemoteSourceBundleUploadRequest::seal(offer_a, &content_a).expect("seal A upload");
    let verification = fixture
        .db
        .verify_task_board_remote_source_bundle_receipt(
            &upload_a,
            PRINCIPAL,
            "instance-b",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("verify A source absence");
    let abandon = RemoteSourceBundleAbandonRequest::seal(&upload_a, verification)
        .expect("seal A abandonment");
    fixture
        .db
        .abandon_task_board_remote_source_bundle(
            &abandon,
            PRINCIPAL,
            "instance-b",
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("abandon generation A");

    // Alias B: distinct assignments reusing A's (execution_id, fencing_epoch),
    // colliding on nothing else. Legitimate reassignment increments the epoch, so
    // same-generation aliasing must fail on both the upload and the inbox.
    let (alias_upload, alias_content) = alias_bundle_offer(
        &fixture.request,
        "assignment-alias-upload",
        "alias-upload-key",
    );
    let accept_alias = rival_offer(
        "assignment-alias-accept",
        "execution-detached",
        "review:alias",
        5,
        "alias-accept-key",
        1,
    );
    assert_aliases_fenced(&fixture.db, &alias_upload, &alias_content, &accept_alias).await;

    // Across restart the abandonment tombstone keeps fencing both aliases.
    fixture.db.pool().close().await;
    let restarted = AsyncDaemonDb::connect(&fixture._temp.path().join("executor.db"))
        .await
        .expect("restart after abandonment");
    assert_aliases_fenced(&restarted, &alias_upload, &alias_content, &accept_alias).await;
}

async fn assert_aliases_fenced(
    db: &AsyncDaemonDb,
    upload_offer: &RemoteOfferRequest,
    upload_content: &[u8],
    accept_offer: &RemoteOfferRequest,
) {
    let before = sequence(db).await;
    let upload = RemoteSourceBundleUploadRequest::seal(upload_offer.clone(), upload_content)
        .expect("seal alias upload");
    let upload_error = db
        .store_task_board_remote_source_bundle(&upload, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect_err("an aliased upload must fail closed against the abandonment")
        .to_string();
    assert!(
        upload_error.contains("durably abandoned"),
        "upload: {upload_error}"
    );
    let accept_error = db
        .accept_task_board_remote_assignment_offer(accept_offer, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect_err("an aliased accept must fail closed against the abandonment")
        .to_string();
    assert!(
        accept_error.contains("durably abandoned"),
        "accept: {accept_error}"
    );
    assert_eq!(
        source_bundle_count(db).await,
        0,
        "a fenced alias must persist no bytes"
    );
    assert_eq!(
        sequence(db).await,
        before,
        "a fenced alias must not mutate state"
    );
}

fn snapshot_offer(template: &RemoteOfferRequest) -> (RemoteOfferRequest, Vec<u8>) {
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

fn alias_bundle_offer(
    template: &RemoteOfferRequest,
    assignment_id: &str,
    idempotency_key: &str,
) -> (RemoteOfferRequest, Vec<u8>) {
    let (mut offer, content) = bundle_offer(template);
    offer.binding.assignment_id = assignment_id.into();
    offer.binding.idempotency_key = idempotency_key.into();
    offer.request_sha256.clear();
    (offer.seal().expect("seal alias bundle offer"), content)
}

fn bundle_offer(template: &RemoteOfferRequest) -> (RemoteOfferRequest, Vec<u8>) {
    let content = b"durable prior phase bundle bytes".to_vec();
    let bundle = RemoteArtifactEntry {
        relative_path: "source/prior-phase.bundle".into(),
        sha256: hex::encode(Sha256::digest(&content)),
        size_bytes: u64::try_from(content.len()).expect("bundle size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = template.clone();
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    offer.source = RemoteSourceMaterial::prior_phase_bundle(
        REPOSITORY,
        PRIOR_BASE,
        SOURCE_REVISION,
        bundle.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![bundle],
    };
    offer.request_sha256.clear();
    (offer.seal().expect("seal bundle offer"), content)
}

async fn insert_archival_assignment(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    idempotency_key: &str,
) {
    sqlx::query(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, idempotency_key, host_id,
             fencing_epoch, state, legacy_migrated, offered_at, completed_at, error,
             updated_at
         ) VALUES (
             ?1, 'execution-legacy-upload', 'planning', ?2, ?3, 1, 'superseded', 1,
             '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z',
             'migrated from dormant v36 assignment; never executable',
             '2026-07-19T08:00:00Z'
         )",
    )
    .bind(assignment_id)
    .bind(idempotency_key)
    .bind(HOST)
    .execute(db.pool())
    .await
    .expect("insert archival legacy assignment");
}

async fn source_bundle_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_remote_source_bundles")
        .fetch_one(db.pool())
        .await
        .expect("count source bundles")
}

async fn sequence(db: &AsyncDaemonDb) -> i64 {
    db.current_change_sequence()
        .await
        .expect("read change sequence")
}

/// Build a real sealed detached offer, then mutate only the collision-relevant
/// identities (and the launch execution/action they must stay consistent with)
/// so each regression isolates one clause of the live fence.
fn rival_offer(
    assignment_id: &str,
    execution_id: &str,
    action_key: &str,
    attempt: u32,
    idempotency_key: &str,
    fencing_epoch: u64,
) -> RemoteOfferRequest {
    let mut offer = detached_offer(assignment_id, idempotency_key);
    offer.binding.execution_id = execution_id.into();
    offer.binding.action_key = action_key.into();
    offer.binding.attempt = attempt;
    offer.binding.fencing_epoch = fencing_epoch;
    offer.launch = test_codex_launch(
        TaskBoardExecutionPhase::Review,
        execution_id,
        action_key,
        "Review the frozen revision",
    );
    offer.request_sha256.clear();
    offer.seal().expect("seal rival offer")
}

/// Insert a truthful current (legacy_migrated = 0) Offered assignment straight
/// from a sealed rival offer. An Offered row deliberately carries no offer
/// receipt, matching the controller-side generation the assignment fence must
/// catch without relying on a receipt.
async fn insert_live_assignment(db: &AsyncDaemonDb, offer: &RemoteOfferRequest) {
    let request_json = serde_json::to_string(offer).expect("serialize rival offer");
    sqlx::query(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
             host_id, target_host_instance_id, fencing_epoch, configuration_revision,
             execution_record_sha256, request_sha256, request_json, authenticated_principal,
             state, legacy_migrated, offered_at, lease_expires_at, deadline_at, updated_at
         ) VALUES (
             ?1, ?2, 'review', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
             'executor:executor-a', 'offered', 0, '2026-07-19T09:00:00Z',
             '2026-07-19T10:05:00Z', ?13, '2026-07-19T09:00:00Z'
         )",
    )
    .bind(&offer.binding.assignment_id)
    .bind(&offer.binding.execution_id)
    .bind(&offer.binding.action_key)
    .bind(i64::from(offer.binding.attempt))
    .bind(&offer.binding.idempotency_key)
    .bind(&offer.binding.host_id)
    .bind(&offer.binding.host_instance_id)
    .bind(i64::try_from(offer.binding.fencing_epoch).expect("rival fencing epoch fits i64"))
    .bind(i64::try_from(offer.binding.configuration_revision).expect("rival config revision"))
    .bind(&offer.binding.execution_record_sha256)
    .bind(&offer.request_sha256)
    .bind(&request_json)
    .bind(&offer.deadline_at)
    .execute(db.pool())
    .await
    .expect("insert live rival assignment");
}
