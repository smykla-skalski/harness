use std::path::Path;
use std::process::Command;

use sha2::{Digest as _, Sha256};

use crate::daemon::db::{
    AsyncDaemonDb, REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture,
    accept_remote_executor, remote_executor_claim_request, remote_executor_fixture,
    remote_executor_identity,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteOfferRequest,
    RemoteSourceBundleUploadRequest, RemoteSourceMaterial, test_codex_launch,
};
use crate::git::source_bundle_export::GitSourceBundleExportPlan;
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardLocalExecutionRepositoryConfig,
    TaskBoardPhaseCapabilityProfile, TaskBoardWorkflowKind,
};

const REPOSITORY: &str = "example/harness";
const CLAIMED_AT: &str = "2026-07-19T10:00:10Z";
const AUTHORITY_AT: &str = "2026-07-19T10:00:20Z";

#[tokio::test]
async fn snapshot_import_survives_restart_then_creates_exact_session_and_cleans_ref() {
    let data = tempfile::tempdir().expect("create isolated data root");
    let data_path = data.path().to_string_lossy().into_owned();
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(data_path.as_str())),
            ("CLAUDE_SESSION_ID", Some("remote-snapshot-restart-test")),
        ],
        async {
            let source = SnapshotSource::new();
            let fixture = remote_executor_fixture(1).await;
            let target = fixture._temp.path().join("configured-checkout");
            init_repository(&target, "target-only\n");
            configure_executor(&fixture, &target).await;
            let offer = snapshot_offer(&fixture.request, &source);
            upload_snapshot(&fixture, &offer, &source.bytes).await;
            let assignment = claim_assignment(&fixture, &offer).await;
            let identity = remote_executor_identity(&assignment).expect("executor identity");
            assert!(!git_object_exists(&target, &source.revision));
            let imported = super::super::source_bundle::materialize_repository_snapshot(
                &fixture.db,
                &assignment,
                &offer,
                &target,
            )
            .await
            .expect("materialize snapshot before simulated crash")
            .expect("snapshot import plan");
            imported.require_imported().expect("durable private snapshot ref");

            let db_path = fixture._temp.path().join("executor.db");
            let RemoteExecutorFixture { db, _temp, .. } = fixture;
            drop(db);
            let reopened = AsyncDaemonDb::connect(&db_path)
                .await
                .expect("reopen snapshot executor database");
            let assignment = reopened
                .task_board_remote_assignment(&assignment.assignment_id)
                .await
                .expect("reload snapshot assignment")
                .expect("snapshot assignment after restart");
            let workspace = super::super::source::ensure_remote_session(
                &reopened,
                &assignment,
                &identity,
                &source.revision,
                true,
                false,
            )
            .await
            .expect("replay import and create exact snapshot session");

            assert_eq!(git(&workspace, &["rev-parse", "HEAD"]), source.revision);
            assert!(!git_ref_exists(&target, &snapshot_import_ref(&offer, &source)));
            let replay = super::super::source::ensure_remote_session(
                &reopened,
                &assignment,
                &identity,
                &source.revision,
                true,
                false,
            )
            .await
            .expect("replay exact snapshot session");
            assert_eq!(replay, workspace);
            assert!(!git_ref_exists(&target, &snapshot_import_ref(&offer, &source)));
        },
    )
    .await;
}

async fn configure_executor(fixture: &RemoteExecutorFixture, repository: &Path) {
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.repositories = vec![TaskBoardLocalExecutionRepositoryConfig {
        repository: REPOSITORY.into(),
        checkout_path: repository.to_string_lossy().into_owned(),
    }];
    settings.local_execution_host.capabilities =
        vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite];
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure snapshot executor");
}

async fn upload_snapshot(
    fixture: &RemoteExecutorFixture,
    offer: &RemoteOfferRequest,
    content: &[u8],
) {
    let upload = RemoteSourceBundleUploadRequest::seal(offer.clone(), content)
        .expect("seal snapshot upload");
    fixture
        .db
        .store_task_board_remote_source_bundle(
            &upload,
            REMOTE_EXECUTOR_PRINCIPAL,
            "instance-a",
            "2026-07-19T10:00:00Z",
        )
        .await
        .expect("persist snapshot upload");
}

async fn claim_assignment(
    fixture: &RemoteExecutorFixture,
    offer: &RemoteOfferRequest,
) -> crate::daemon::db::TaskBoardRemoteAssignmentRecord {
    let accepted = accept_remote_executor(fixture, offer).await;
    fixture
        .db
        .claim_task_board_remote_assignment(
            &remote_executor_claim_request(offer, &accepted),
            REMOTE_EXECUTOR_PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("claim snapshot assignment");
    fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &offer.binding.assignment_id,
            "instance-a",
            AUTHORITY_AT,
        )
        .await
        .expect("claim snapshot start authority")
        .expect("snapshot start remains authorized");
    fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load snapshot claim")
        .expect("snapshot claim")
}

fn snapshot_offer(template: &RemoteOfferRequest, source: &SnapshotSource) -> RemoteOfferRequest {
    let artifact = RemoteArtifactEntry {
        relative_path: "source/repository-snapshot.bundle".into(),
        sha256: source.sha256.clone(),
        size_bytes: u64::try_from(source.bytes.len()).expect("snapshot size"),
        media_type: "application/x-git-bundle".into(),
    };
    let mut offer = template.clone();
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    offer.binding.phase = TaskBoardExecutionPhase::Implementation;
    offer.binding.action_key = "implementation:1".into();
    offer.binding.repository = REPOSITORY.into();
    offer.binding.base_revision.clone_from(&source.revision);
    offer.binding.expected_head_revision = None;
    offer.launch = test_codex_launch(
        TaskBoardExecutionPhase::Implementation,
        &offer.binding.execution_id,
        &offer.binding.action_key,
        "Implement from the exact repository snapshot",
    );
    offer.source = RemoteSourceMaterial::repository_snapshot_bundle(
        REPOSITORY,
        &source.revision,
        artifact.clone(),
    );
    offer.artifacts = RemoteArtifactManifest {
        entries: vec![artifact],
    };
    offer.request_sha256.clear();
    offer.seal().expect("seal snapshot offer")
}

struct SnapshotSource {
    _temp: tempfile::TempDir,
    revision: String,
    bytes: Vec<u8>,
    sha256: String,
}

impl SnapshotSource {
    fn new() -> Self {
        let temp = tempfile::tempdir().expect("create snapshot source");
        init_repository(temp.path(), "snapshot-only\n");
        let revision = git(temp.path(), &["rev-parse", "HEAD"]);
        let export = GitSourceBundleExportPlan::for_revision(
            temp.path(),
            REPOSITORY.into(),
            revision.clone(),
        )
        .expect("snapshot export plan")
        .export(4 * 1024 * 1024)
        .expect("snapshot export");
        Self {
            _temp: temp,
            revision,
            sha256: hex::encode(Sha256::digest(&export.bytes)),
            bytes: export.bytes,
        }
    }
}

fn init_repository(path: &Path, content: &str) {
    std::fs::create_dir_all(path).expect("create snapshot repository");
    git(path, &["init", "-q", "-b", "main"]);
    git(path, &["config", "user.name", "Harness Test"]);
    git(path, &["config", "user.email", "harness@example.com"]);
    git(
        path,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/example/harness.git",
        ],
    );
    std::fs::write(path.join("source.txt"), content).expect("write snapshot source");
    git(path, &["add", "source.txt"]);
    git(path, &["commit", "-qm", "source"]);
}

fn snapshot_import_ref(offer: &RemoteOfferRequest, source: &SnapshotSource) -> String {
    format!(
        "refs/harness/task-board/source-imports/{}/{}",
        offer.request_sha256, source.sha256
    )
}

fn git_object_exists(repository: &Path, revision: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(["cat-file", "-e", &format!("{revision}^{{commit}}")])
        .output()
        .expect("query snapshot object")
        .status
        .success()
}

fn git_ref_exists(repository: &Path, reference: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(["rev-parse", "--verify", "--quiet", reference])
        .output()
        .expect("query snapshot ref")
        .status
        .success()
}

fn git(repository: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output utf8")
        .trim()
        .to_owned()
}
