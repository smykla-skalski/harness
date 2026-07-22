use std::path::Path;

use sha2::{Digest as _, Sha256};

use crate::daemon::db::{
    AsyncDaemonDb, REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture,
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopReason,
    TaskBoardRemoteMutationOutcome, accept_remote_executor, remote_executor_claim_request,
    remote_executor_fixture, remote_executor_identity,
};
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAssignmentWireState,
    RemoteOfferRequest, RemoteSettledRequest, RemoteSourceBundleUploadRequest,
    RemoteSourceMaterial, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::git::bundle_export::GitBundleExportPlan;
use crate::task_board::{
    TaskBoardLocalExecutionRepositoryConfig, TaskBoardWorkflowKind,
};

const CLAIMED_AT: &str = "2026-07-19T10:00:10Z";
const AUTHORITY_AT: &str = "2026-07-19T10:00:20Z";
const STARTED_AT: &str = "2026-07-19T10:00:30Z";
const UNKNOWN_AT: &str = "2026-07-19T10:00:40Z";
const EXPIRED_AT: &str = "2026-07-19T10:11:00Z";

#[tokio::test]
async fn prior_phase_import_ref_is_cleaned_before_durable_cleanup_marker() {
    let data = tempfile::tempdir().expect("create isolated data root");
    let data_path = data.path().to_string_lossy().into_owned();
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(data_path.as_str())),
            ("CLAUDE_SESSION_ID", Some("remote-bundle-cleanup-test")),
        ],
        async {
            let source = BundleSource::new();
            let fixture = remote_executor_fixture(1).await;
            configure_executor(&fixture, source.repository.path()).await;
            let (offer, bundle_sha256) = bundle_offer(&fixture.request, &source);
            upload_bundle(&fixture, &offer, &source.bytes).await;
            let (assignment, authority) = claim_with_start_authority(&fixture, &offer).await;
            let identity = remote_executor_identity(&assignment).expect("executor identity");
            let workspace = super::super::source::ensure_remote_session(
                &fixture.db,
                &assignment,
                &identity,
                &source.base,
                true,
                false,
            )
            .await
            .expect("create exact base session");
            super::super::source_bundle::apply_prior_phase_bundle(
                &fixture.db,
                &assignment,
                &offer,
                &identity,
                &workspace,
            )
            .await
            .expect("apply prior-phase bundle");
            assert_eq!(super::git(&workspace, &["rev-parse", "HEAD"]), source.result);
            let import_ref = format!(
                "refs/harness/task-board/imports/{}/{bundle_sha256}",
                offer.request_sha256
            );
            assert_eq!(
                super::git(source.repository.path(), &["rev-parse", &import_ref]),
                source.result
            );

            let unknown =
                stop_unadopted_to_unknown(&fixture, &assignment, &authority, &workspace).await;
            settle_unknown(&fixture.db, &unknown).await;
            assert_ref_drift_blocks_cleanup(
                &fixture.db,
                &unknown,
                &source,
                &import_ref,
                &workspace,
            )
            .await;
            super::super::reconcile_remote_executor_assignment(
                &super::super::disabled_tests::executor_state(
                    &fixture.db,
                    "restarted-instance",
                ),
                &fixture.db,
                &unknown.assignment_id,
            )
            .await
            .expect("clean settled prior-phase executor state");

            let cleaned = fixture
                .db
                .task_board_remote_assignment(&unknown.assignment_id)
                .await
                .expect("load cleaned bundle assignment")
                .expect("cleaned bundle assignment");
            assert!(cleaned.cleanup_completed_at.is_some());
            assert!(!workspace.exists());
            assert!(!git_ref_exists(source.repository.path(), &import_ref));
            assert!(
                fixture
                    .db
                    .task_board_remote_source_bundle(&cleaned)
                    .await
                    .expect("load retained source-bundle evidence")
                    .is_some()
            );
        },
    )
    .await;
}

async fn assert_ref_drift_blocks_cleanup(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    source: &BundleSource,
    import_ref: &str,
    workspace: &Path,
) {
    super::git(
        source.repository.path(),
        &["update-ref", import_ref, &source.base, &source.result],
    );
    let error = super::super::reconcile_remote_executor_assignment(
        &super::super::disabled_tests::executor_state(db, "restarted-instance"),
        db,
        &record.assignment_id,
    )
    .await
    .expect_err("drifted private import ref must block cleanup");
    assert!(
        error.to_string().contains("bundle import ref changed"),
        "unexpected import-ref fence: {error}"
    );
    let blocked = db
        .task_board_remote_assignment(&record.assignment_id)
        .await
        .expect("reload blocked cleanup")
        .expect("blocked cleanup assignment");
    assert!(blocked.cleanup_completed_at.is_none());
    assert!(workspace.exists());
    assert_eq!(
        super::git(source.repository.path(), &["rev-parse", import_ref]),
        source.base
    );
    super::git(
        source.repository.path(),
        &["update-ref", import_ref, &source.result, &source.base],
    );
}

struct BundleSource {
    repository: tempfile::TempDir,
    base: String,
    result: String,
    advertised_ref: String,
    bytes: Vec<u8>,
}

impl BundleSource {
    fn new() -> Self {
        let repository = tempfile::tempdir().expect("create bundle source");
        super::git(repository.path(), &["init", "-q", "-b", "main"]);
        super::git(repository.path(), &["config", "user.name", "Harness Test"]);
        super::git(
            repository.path(),
            &["config", "user.email", "harness@example.com"],
        );
        std::fs::write(repository.path().join("result.txt"), "base\n")
            .expect("write bundle base");
        super::git(repository.path(), &["add", "result.txt"]);
        super::git(repository.path(), &["commit", "-qm", "base"]);
        let base = super::git(repository.path(), &["rev-parse", "HEAD"]);
        std::fs::write(repository.path().join("result.txt"), "result\n")
            .expect("write bundle result");
        super::git(repository.path(), &["commit", "-qam", "result"]);
        let result = super::git(repository.path(), &["rev-parse", "HEAD"]);
        let export = GitBundleExportPlan::for_result(
            repository.path(),
            base.clone(),
            result.clone(),
        )
        .expect("plan prior-phase export")
        .export(1024 * 1024)
        .expect("export prior-phase bundle");
        Self {
            repository,
            base,
            result,
            advertised_ref: export.advertised_ref,
            bytes: export.bytes,
        }
    }
}

async fn configure_executor(fixture: &RemoteExecutorFixture, repository: &Path) {
    // Session provisioning canonicalizes origin_path, so resolve macOS
    // /var -> /private/var or exact_provisioned_session never matches when the
    // Start-I/O permit later reconciles this frozen checkout.
    let repository = repository
        .canonicalize()
        .unwrap_or_else(|_| repository.to_path_buf());
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.repositories = vec![TaskBoardLocalExecutionRepositoryConfig {
        repository: "example/harness".into(),
        checkout_path: repository.to_string_lossy().into_owned(),
    }];
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure source checkout");
}

fn bundle_offer(
    template: &RemoteOfferRequest,
    source: &BundleSource,
) -> (RemoteOfferRequest, String) {
    let bundle_sha256 = hex::encode(Sha256::digest(&source.bytes));
    let artifact = RemoteArtifactEntry {
        relative_path: "source/prior-phase.bundle".into(),
        sha256: bundle_sha256.clone(),
        size_bytes: u64::try_from(source.bytes.len()).expect("bundle size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = template.clone();
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    offer.binding.base_revision.clone_from(&source.result);
    offer.binding.expected_head_revision = Some(source.result.clone());
    offer.source = RemoteSourceMaterial::prior_phase_bundle(
        "example/harness",
        &source.base,
        &source.result,
        artifact.clone(),
    );
    if let RemoteSourceMaterial::PriorPhaseBundle { advertised_ref, .. } = &offer.source {
        assert_eq!(advertised_ref, &source.advertised_ref);
    }
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![artifact],
    };
    offer.request_sha256.clear();
    (offer.seal().expect("seal bundle offer"), bundle_sha256)
}

async fn upload_bundle(
    fixture: &RemoteExecutorFixture,
    offer: &RemoteOfferRequest,
    content: &[u8],
) {
    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), content)
        .expect("seal bundle upload");
    fixture
        .db
        .store_task_board_remote_source_bundle(
            &upload,
            REMOTE_EXECUTOR_PRINCIPAL,
            "instance-a",
            "2026-07-19T10:00:00Z",
        )
        .await
        .expect("persist immutable source bundle");
}

async fn claim_with_start_authority(
    fixture: &RemoteExecutorFixture,
    offer: &RemoteOfferRequest,
) -> (
    TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorStartAuthority,
) {
    let accepted = accept_remote_executor(fixture, offer).await;
    fixture
        .db
        .claim_task_board_remote_assignment(
            &remote_executor_claim_request(offer, &accepted),
            REMOTE_EXECUTOR_PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("claim source-backed assignment");
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            "instance-a",
            AUTHORITY_AT,
        )
        .await
        .expect("claim source-backed start authority")
        .expect("source-backed start authority");
    let assignment = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load source-backed claim")
        .expect("source-backed claim");
    (assignment, authority)
}

/// Drives the provisioned source-backed generation to a terminal `Unknown` the
/// way an executor actually reaches it with its session and private import ref
/// intact: it acquires the Start-I/O permit, finds the fresh run invalid, and
/// stops-and-settles it. The unprovisioned no-run expiry cannot represent this
/// state - it fences a present session as durable provisioning evidence - so
/// the durable settled cleanup is the only path that reclaims the import ref.
async fn stop_unadopted_to_unknown(
    fixture: &RemoteExecutorFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    workspace: &Path,
) -> TaskBoardRemoteAssignmentRecord {
    let permit = fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(authority, workspace, STARTED_AT)
        .await
        .expect("claim exact Start I/O permit")
        .expect_acquired("Start I/O remains permitted");
    let invalid = invalid_run(assignment, authority, workspace);
    fixture
        .db
        .save_codex_run(&invalid)
        .await
        .expect("persist stopped executor run");
    let pending = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &TaskBoardRemoteExecutorStopAuthority::Start(permit),
            &invalid,
            TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
            UNKNOWN_AT,
        )
        .await
        .expect("claim exact stop-only authority")
        .expect("stop-only authority");
    let TaskBoardRemoteMutationOutcome::Updated(unknown) = fixture
        .db
        .settle_task_board_remote_executor_stop_pending(&pending, UNKNOWN_AT)
        .await
        .expect("settle exact stopped run")
    else {
        panic!("stopped source-backed run did not become unknown");
    };
    unknown
}

fn invalid_run(
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    workspace: &Path,
) -> CodexRunSnapshot {
    let request = assignment
        .require_offer()
        .expect("strict source-backed offer")
        .launch
        .codex_request();
    CodexRunSnapshot {
        run_id: authority.identity.run_id.clone(),
        session_id: authority.identity.session_id.clone(),
        task_id: request.task_id,
        board_item_id: request.board_item_id,
        workflow_execution_id: request.workflow_execution_id,
        session_agent_id: None,
        display_name: request.name,
        project_dir: workspace.to_string_lossy().into_owned(),
        thread_id: request.resume_thread_id,
        turn_id: None,
        mode: request.mode,
        status: CodexRunStatus::Cancelled,
        prompt: "mismatched executor launch".into(),
        latest_summary: None,
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: STARTED_AT.into(),
        updated_at: UNKNOWN_AT.into(),
        model: request.model,
        effort: request.effort,
    }
}

async fn settle_unknown(db: &AsyncDaemonDb, record: &TaskBoardRemoteAssignmentRecord) {
    let offer = record.require_offer().expect("strict source-backed offer");
    let settlement = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record.lease_id.clone().expect("source-backed lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Unknown,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal source-backed settlement");
    db.settle_task_board_remote_assignment(
        &settlement,
        REMOTE_EXECUTOR_PRINCIPAL,
        EXPIRED_AT,
    )
    .await
    .expect("settle source-backed assignment");
}

fn git_ref_exists(repository: &Path, reference: &str) -> bool {
    std::process::Command::new("git")
        .args(["rev-parse", "--verify", "--quiet", reference])
        .current_dir(repository)
        .output()
        .expect("query Git ref")
        .status
        .success()
}
