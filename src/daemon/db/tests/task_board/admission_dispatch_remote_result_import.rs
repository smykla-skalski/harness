use std::path::{Path, PathBuf};
use std::process::Command;

use fs_err as fs;
use sha2::{Digest, Sha256};
use tempfile::TempDir;

use super::completion_evidence_tests::{
    accepted_offer, intent_status, remote_status, remote_status_request,
};
use super::remote_start_tests::{
    PreparedRemoteOffer, offer_remote,
};
use super::*;
use crate::daemon::db::task_board::remote_assignment_test_support::claim_request;
use crate::daemon::db::task_board::{
    REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE, REMOTE_IMPLEMENTATION_BUNDLE_PATH,
    REMOTE_RESULT_ARTIFACT_MEDIA_TYPE, REMOTE_RESULT_ARTIFACT_PATH,
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteResultImportRequest,
    TaskBoardRemoteResultImportState,
};
use crate::daemon::service::import_task_board_remote_implementation_result;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAssignmentWireState, RemoteClaimResponse,
    RemoteLease, RemoteStatusResponse, RemoteTypedResult, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
    TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE, TaskBoardAttemptResultArtifact,
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardImplementationResult, TaskBoardLocalAttemptResult, TaskBoardStatus,
    TaskBoardWorkflowExecutionCas,
};

const PRINCIPAL: &str = "executor-a";
const IMPORT_REF: &str =
    "refs/harness/task-board/imports/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[path = "admission_dispatch_remote_result_import_support.rs"]
mod support;
pub(crate) use support::prepare_remote_implementation_offer;

#[path = "admission_dispatch_remote_result_import_replay_tests.rs"]
mod replay_tests;

#[path = "admission_dispatch_remote_result_import_replay_safety_tests.rs"]
mod replay_safety_tests;

struct ImportCandidate {
    prepared: PreparedRemoteOffer,
    parent: crate::task_board::TaskBoardWorkflowExecutionRecord,
    request: TaskBoardRemoteResultImportRequest,
    item_id: String,
    git: ImportGitFixture,
}

async fn import_candidate(label: &str) -> ImportCandidate {
    let mut git = ImportGitFixture::new();
    let prepared = prepare_remote_implementation_offer(label, git.worktree(), &git.base).await;
    git.bind_session_branch(&prepared);
    offer_and_accept(&prepared).await;
    let (response, result_entry) = terminal_response(&prepared, &git);
    record_terminal_status(&prepared, &response).await;
    store_artifact(&prepared, &result_entry, &serde_json::to_vec(
        response.result.as_ref().expect("typed implementation result"),
    ).expect("serialize typed result")).await;
    let bundle_entry = response.output_artifacts.entries[1].clone();
    store_artifact(&prepared, &bundle_entry, &git.bundle).await;
    let parent = load_parent(&prepared).await;
    let request = git.request(&prepared);
    ImportCandidate {
        prepared,
        parent,
        request,
        item_id: format!("admission-write-{label}"),
        git,
    }
}

async fn offer_and_accept(prepared: &PreparedRemoteOffer) {
    offer_remote(prepared, "2026-07-19T10:00:00Z", "2026-07-19T10:01:00Z")
        .await
        .expect("offer implementation assignment");
    prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            PRINCIPAL,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer authority")
        .expect("offer remains active");
    prepared
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&prepared.offer),
            PRINCIPAL,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("record accepted offer");
    let assignment = prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load accepted assignment")
        .expect("accepted assignment");
    let claim = claim_request(&prepared.offer, &assignment);
    prepared
        .db
        .claim_task_board_remote_claim_io_authority(&claim, PRINCIPAL, "2026-07-19T10:00:02Z")
        .await
        .expect("claim remote claim authority")
        .expect("claim remains active");
    // Record the executor's claim response so the controller settles the claim I/O
    // authority the same way the live path does; the terminal import target is then
    // authority-free.
    prepared
        .db
        .record_task_board_remote_assignment_claim(
            &claim,
            &RemoteClaimResponse {
                schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
                binding: prepared.offer.binding.clone(),
                offer_request_sha256: prepared.offer.request_sha256.clone(),
                lease: RemoteLease {
                    lease_id: claim.lease_id.clone(),
                    expires_at: "2026-07-19T10:01:00Z".into(),
                },
                claimed_at: "2026-07-19T10:00:02Z".into(),
            },
            PRINCIPAL,
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("record remote claim response");
}

fn terminal_response(
    prepared: &PreparedRemoteOffer,
    git: &ImportGitFixture,
) -> (RemoteStatusResponse, RemoteArtifactEntry) {
    let typed = RemoteTypedResult::seal(
        TaskBoardLocalAttemptResult {
            schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
            execution_id: prepared.offer.binding.execution_id.clone(),
            action_key: prepared.offer.binding.action_key.clone(),
            attempt: prepared.offer.binding.attempt,
            idempotency_key: prepared.offer.binding.idempotency_key.clone(),
            exact_head_revision: git.result.clone(),
            artifact: TaskBoardAttemptResultArtifact::Implementation(
                TaskBoardImplementationResult {
                    revision_cycle: 1,
                    base_head_revision: git.base.clone(),
                    head_revision: git.result.clone(),
                    summary: "implemented remotely".into(),
                    evidence: Vec::new(),
                },
            ),
        },
        prepared.offer.request_sha256.clone(),
    )
    .expect("seal implementation result");
    let result_bytes = serde_json::to_vec(&typed).expect("serialize implementation result");
    let result_entry = artifact_entry(
        REMOTE_RESULT_ARTIFACT_PATH,
        REMOTE_RESULT_ARTIFACT_MEDIA_TYPE,
        &result_bytes,
    );
    let bundle_entry = artifact_entry(
        REMOTE_IMPLEMENTATION_BUNDLE_PATH,
        REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE,
        &git.bundle,
    );
    let mut response = remote_status(&prepared.offer, RemoteAssignmentWireState::Running, true);
    response.state = RemoteAssignmentWireState::Completed;
    response.lease = Some(RemoteLease {
        lease_id: "lease-admission".into(),
        expires_at: "2026-07-19T10:01:00Z".into(),
    });
    response.result = Some(typed);
    response.output_artifacts = RemoteArtifactManifest {
        entries: vec![result_entry.clone(), bundle_entry],
    };
    response.observed_at = "2026-07-19T10:00:05Z".into();
    response.status_sha256.clear();
    (response.seal().expect("seal completed implementation status"), result_entry)
}

async fn record_terminal_status(
    prepared: &PreparedRemoteOffer,
    response: &RemoteStatusResponse,
) {
    assert!(matches!(
        prepared
            .db
            .record_task_board_remote_assignment_status(
                &remote_status_request(&prepared.offer),
                response,
                PRINCIPAL,
            )
            .await
            .expect("record provisional terminal status"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
}

async fn store_artifact(
    prepared: &PreparedRemoteOffer,
    entry: &RemoteArtifactEntry,
    content: &[u8],
) {
    let assignment = prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load terminal assignment")
        .expect("terminal assignment");
    prepared
        .db
        .store_task_board_remote_artifact(
            &prepared.offer.binding,
            assignment.lease_id.as_deref().expect("terminal lease"),
            &prepared.offer.request_sha256,
            entry,
            content,
            PRINCIPAL,
            "2026-07-19T10:00:06Z",
        )
        .await
        .expect("store fetched implementation artifact");
}

fn artifact_entry(path: &str, media_type: &str, content: &[u8]) -> RemoteArtifactEntry {
    RemoteArtifactEntry {
        relative_path: path.into(),
        sha256: hex::encode(Sha256::digest(content)),
        size_bytes: u64::try_from(content.len()).expect("artifact size"),
        media_type: media_type.into(),
    }
}

async fn import_result(
    candidate: &ImportCandidate,
    parent: &crate::task_board::TaskBoardWorkflowExecutionRecord,
) -> crate::daemon::db::task_board::TaskBoardRemoteResultImportRecord {
    import_task_board_remote_implementation_result(
        &candidate.prepared.db,
        &TaskBoardWorkflowExecutionCas::from(parent),
        &candidate.request,
    )
    .await
    .expect("import implementation result")
}

async fn load_parent(
    prepared: &PreparedRemoteOffer,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    prepared
        .db
        .task_board_workflow_execution(&prepared.execution_id)
        .await
        .expect("load implementation workflow")
        .expect("implementation workflow")
}

struct ImportGitFixture {
    _directory: TempDir,
    controller: PathBuf,
    bundle: Vec<u8>,
    base: String,
    result: String,
    result_ref: String,
    git_dir: String,
    common_git_dir: String,
    branch_ref: String,
}

impl ImportGitFixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().expect("git fixture directory");
        let source = directory.path().join("source");
        let controller = directory.path().join("controller");
        fs::create_dir_all(&source).expect("source repository directory");
        run_git(&source, &["init", "-b", "main"]);
        configure(&source);
        fs::write(source.join("README.md"), "base\n").expect("base file");
        run_git(&source, &["add", "README.md"]);
        run_git(&source, &["commit", "-m", "base"]);
        let base = git(&source, &["rev-parse", "HEAD"]);
        run_git(directory.path(), &["clone", path(&source), path(&controller)]);
        // Canonicalize the checked-out worktree so it matches the frozen run
        // context and the plan evidence (macOS /var vs /private/var); the import
        // target gate compares all three for exact equality.
        let controller = controller
            .canonicalize()
            .expect("canonical controller worktree");
        configure(&controller);
        fs::write(source.join("result.txt"), "result\n").expect("result file");
        run_git(&source, &["add", "result.txt"]);
        run_git(&source, &["commit", "-m", "result"]);
        let result = git(&source, &["rev-parse", "HEAD"]);
        // The production import derives the sealed result ref from the result
        // revision, so the bundle must advertise that exact ref, not a placeholder.
        let result_ref = format!("refs/harness/task-board/results/{result}");
        run_git(&source, &["update-ref", &result_ref, &result]);
        let bundle_path = directory.path().join("implementation.bundle");
        run_git(
            &source,
            &[
                "bundle",
                "create",
                "--version=2",
                path(&bundle_path),
                &result_ref,
                &format!("^{base}"),
            ],
        );
        let bundle = fs::read(&bundle_path).expect("read bundle bytes");
        let git_dir = PathBuf::from(git(&controller, &["rev-parse", "--absolute-git-dir"]))
            .canonicalize()
            .expect("canonical controller git dir")
            .to_string_lossy()
            .into_owned();
        let common_git_dir = PathBuf::from(git(
            &controller,
            &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        ))
        .canonicalize()
        .expect("canonical controller common git dir")
        .to_string_lossy()
        .into_owned();
        Self {
            _directory: directory,
            controller,
            bundle,
            base,
            result,
            result_ref,
            git_dir,
            common_git_dir,
            branch_ref: "refs/heads/main".into(),
        }
    }

    fn worktree(&self) -> &str {
        path(&self.controller)
    }

    fn request(&self, prepared: &PreparedRemoteOffer) -> TaskBoardRemoteResultImportRequest {
        TaskBoardRemoteResultImportRequest {
            assignment_id: prepared.offer.binding.assignment_id.clone(),
            fencing_epoch: 1,
            worktree_path: self.worktree().into(),
            git_dir: self.git_dir.clone(),
            common_git_dir: self.common_git_dir.clone(),
            branch_ref: self.branch_ref.clone(),
            base_revision: self.base.clone(),
            result_revision: self.result.clone(),
            advertised_ref: self.result_ref.clone(),
            import_ref: IMPORT_REF.into(),
            object_format: "sha1".into(),
            prepared_at: "2026-07-19T10:00:07Z".into(),
        }
    }

    fn assert_applied(&self) {
        assert_eq!(
            git(&self.controller, &["symbolic-ref", "HEAD"]),
            self.branch_ref
        );
        assert_eq!(git(&self.controller, &["rev-parse", "HEAD"]), self.result);
        assert_eq!(git(&self.controller, &["rev-parse", IMPORT_REF]), self.result);
        assert!(git(&self.controller, &["status", "--porcelain"]).is_empty());
    }

    fn bind_session_branch(&mut self, prepared: &PreparedRemoteOffer) {
        let session_id = &prepared
            .execution
            .snapshot
            .read_only_run_context
            .as_ref()
            .expect("frozen import run context")
            .session_id;
        let short = format!("harness/{session_id}");
        run_git(&self.controller, &["branch", "-m", &short]);
        self.branch_ref = format!("refs/heads/{short}");
    }
}

fn configure(repository: &Path) {
    run_git(repository, &["config", "user.name", "Harness Test"]);
    run_git(repository, &["config", "user.email", "test@example.com"]);
}

fn run_git(repository: &Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git");
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

fn git(repository: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git");
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn path(path: &Path) -> &str {
    path.to_str().expect("utf8 test path")
}
