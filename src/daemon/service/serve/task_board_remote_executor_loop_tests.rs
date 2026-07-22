use std::process::Command;

use super::{
    RemoteWorkerAction, remote_codex_request, start_window_is_open, validate_run_identity,
    worker_action,
};
use crate::daemon::db::remote_executor_identity_from_parts;
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAttemptBinding, RemoteOfferRequest,
    RemoteSourceMaterial, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, test_codex_launch,
};
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState, TaskBoardWorkflowKind,
};

const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const REVISION: &str = "1111111111111111111111111111111111111111";

#[test]
fn deterministic_worker_identity_is_generation_bound_and_opaque() {
    let first = remote_executor_identity_from_parts("assignment-1", 1, DIGEST);
    let replay = remote_executor_identity_from_parts("assignment-1", 1, DIGEST);
    let next = remote_executor_identity_from_parts("assignment-1", 2, DIGEST);

    assert_eq!(first, replay);
    assert_ne!(first, next);
    assert!(uuid::Uuid::parse_str(&first.session_id).is_ok());
    assert!(!first.workspace_ref.contains('/'));
    assert!(first.run_id.starts_with("remote-codex-"));
}

#[test]
fn start_action_adopts_the_exact_run_before_persisting_start_evidence() {
    assert_eq!(
        worker_action(TaskBoardRemoteAssignmentState::Claimed, None),
        RemoteWorkerAction::Start
    );
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Claimed,
            Some(CodexRunStatus::Running)
        ),
        RemoteWorkerAction::Probe
    );
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Claimed,
            Some(CodexRunStatus::Completed)
        ),
        RemoteWorkerAction::Probe
    );
    assert_eq!(
        worker_action(TaskBoardRemoteAssignmentState::Started, None),
        RemoteWorkerAction::Hold
    );
    assert_eq!(
        worker_action(TaskBoardRemoteAssignmentState::Running, None),
        RemoteWorkerAction::Hold
    );
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Started,
            Some(CodexRunStatus::Completed)
        ),
        RemoteWorkerAction::Probe
    );
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Running,
            Some(CodexRunStatus::Failed)
        ),
        RemoteWorkerAction::Probe
    );
}

#[test]
fn runtime_thread_is_mutable_after_the_sealed_launch() {
    let offer = repository_offer(TaskBoardExecutionPhase::Review)
        .seal()
        .expect("seal thread-validation offer");
    let identity = remote_executor_identity_from_parts(
        &offer.binding.assignment_id,
        offer.binding.fencing_epoch,
        &offer.request_sha256,
    );
    let request = remote_codex_request(&offer);
    assert!(request.resume_thread_id.is_none());
    let mut snapshot = CodexRunSnapshot {
        run_id: identity.run_id.clone(),
        session_id: identity.session_id.clone(),
        task_id: request.task_id.clone(),
        board_item_id: request.board_item_id.clone(),
        workflow_execution_id: request.workflow_execution_id.clone(),
        session_agent_id: None,
        display_name: request.name.clone(),
        project_dir: "/tmp/remote-thread-worktree".into(),
        thread_id: None,
        turn_id: None,
        mode: request.mode,
        status: CodexRunStatus::Running,
        prompt: request.prompt.clone(),
        latest_summary: None,
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-07-19T10:00:20Z".into(),
        updated_at: "2026-07-19T10:00:20Z".into(),
        model: request.model.clone(),
        effort: request.effort.clone(),
    };
    validate_run_identity(&snapshot, &offer, &identity).expect("validate pre-thread run");
    snapshot.thread_id = Some("thread-normal-start".into());
    validate_run_identity(&snapshot, &offer, &identity)
        .expect("validate normal post-start thread evidence");
    snapshot.thread_id = Some("   ".into());
    assert!(validate_run_identity(&snapshot, &offer, &identity).is_err());
}

#[test]
fn durable_cancel_stops_only_an_active_exact_worker() {
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Cancelled,
            Some(CodexRunStatus::WaitingApproval)
        ),
        RemoteWorkerAction::Cancel
    );
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Cancelled,
            Some(CodexRunStatus::Completed)
        ),
        RemoteWorkerAction::Hold
    );
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Unknown,
            Some(CodexRunStatus::Running)
        ),
        RemoteWorkerAction::Cancel
    );
    assert_eq!(
        worker_action(
            TaskBoardRemoteAssignmentState::Unknown,
            Some(CodexRunStatus::Completed)
        ),
        RemoteWorkerAction::Hold
    );
}

#[test]
fn worker_start_requires_an_unexpired_lease_and_deadline() {
    let now = "2026-07-20T12:00:00Z";
    assert!(start_window_is_open("2026-07-20T12:00:01Z", "2026-07-20T12:01:00Z", now).unwrap());
    assert!(!start_window_is_open(now, "2026-07-20T12:01:00Z", now).unwrap());
    assert!(!start_window_is_open("2026-07-20T12:01:00Z", now, now).unwrap());
}

#[test]
fn fork_repository_and_prior_phase_bundle_expose_their_initial_revision() {
    let mut forked = repository_offer(TaskBoardExecutionPhase::Implementation);
    forked.binding.workflow_kind = TaskBoardWorkflowKind::PrFix;
    // The binding repository tracks the fork even for a PR-fix source branch.
    forked.binding.repository = "contributor/repo".into();
    forked.source =
        RemoteSourceMaterial::repository_branch("contributor/repo", "feature/fix", REVISION);
    forked = forked.seal().expect("seal fork repository offer");
    assert_eq!(
        super::source::initial_source_revision(&forked).expect("resolve fork revision"),
        REVISION
    );

    let artifact = RemoteArtifactEntry {
        relative_path: "source.bundle".into(),
        sha256: DIGEST.into(),
        size_bytes: 64,
        media_type: "application/x-git-bundle".into(),
    };
    let mut bundled = repository_offer(TaskBoardExecutionPhase::Review);
    bundled.artifacts.entries.push(artifact.clone());
    bundled.source = RemoteSourceMaterial::prior_phase_bundle(
        "org/repo",
        "2222222222222222222222222222222222222222",
        REVISION,
        artifact,
    );
    bundled = bundled.seal().expect("seal bundle offer");
    assert_eq!(
        super::source::initial_source_revision(&bundled).expect("resolve bundle base revision"),
        "2222222222222222222222222222222222222222"
    );
}

#[test]
fn probe_accepts_a_legitimate_implementation_head_advance() {
    let checkout = tempfile::tempdir().expect("create checkout");
    git(checkout.path(), &["init", "-q"]);
    git(checkout.path(), &["config", "user.name", "Harness Test"]);
    git(
        checkout.path(),
        &["config", "user.email", "harness@example.com"],
    );
    std::fs::write(checkout.path().join("result.txt"), "base\n").expect("write base");
    git(checkout.path(), &["add", "result.txt"]);
    git(checkout.path(), &["commit", "-qm", "base"]);
    let base = git(checkout.path(), &["rev-parse", "HEAD"]);
    super::source::validate_remote_worktree_head(checkout.path(), &base, true)
        .expect("sealed source head");

    std::fs::write(checkout.path().join("result.txt"), "implementation\n")
        .expect("write implementation");
    git(checkout.path(), &["commit", "-qam", "implementation"]);
    assert!(super::source::validate_remote_worktree_head(checkout.path(), &base, true).is_err());
    super::source::validate_remote_worktree_head(checkout.path(), &base, false)
        .expect("probe accepts the worker output head");
}

#[test]
fn phase_selects_the_narrow_codex_mode() {
    let implementation =
        remote_codex_request(&repository_offer(TaskBoardExecutionPhase::Implementation));
    assert_eq!(implementation.mode, CodexRunMode::WorkspaceWrite);

    let mut review = repository_offer(TaskBoardExecutionPhase::Review);
    let artifact = RemoteArtifactEntry {
        relative_path: "source.bundle".into(),
        sha256: DIGEST.into(),
        size_bytes: 64,
        media_type: "application/x-git-bundle".into(),
    };
    review.artifacts.entries.push(artifact.clone());
    review.source = RemoteSourceMaterial::prior_phase_bundle(
        "org/repo",
        "2222222222222222222222222222222222222222",
        REVISION,
        artifact,
    );
    review.launch.capabilities = vec![
        "task-board".into(),
        "task-board:tag:security".into(),
        "task-board:attempt:review:security".into(),
    ];
    review.launch.display_name = "Task Board Review: Remote contract".into();
    review.launch.persona = Some("security-reviewer".into());
    review.launch.model = Some("gpt-5.4".into());
    review.launch.effort = Some("high".into());
    let review = review.seal().expect("seal review offer");
    let request = remote_codex_request(&review);
    assert_eq!(request.mode, CodexRunMode::Report);
    assert_eq!(request.capabilities, review.launch.capabilities);
    assert_eq!(
        request.name.as_deref(),
        Some("Task Board Review: Remote contract")
    );
    assert_eq!(request.persona.as_deref(), Some("security-reviewer"));
    assert_eq!(request.model.as_deref(), Some("gpt-5.4"));
    assert_eq!(request.effort.as_deref(), Some("high"));
    assert!(!request.allow_custom_model);
}

fn repository_offer(phase: TaskBoardExecutionPhase) -> RemoteOfferRequest {
    let expected_head_revision =
        (!matches!(phase, TaskBoardExecutionPhase::Implementation)).then(|| REVISION.to_string());
    RemoteOfferRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: RemoteAttemptBinding {
            assignment_id: "assignment-1".into(),
            execution_id: "execution-1".into(),
            phase,
            workflow_kind: TaskBoardWorkflowKind::DefaultTask,
            action_key: match phase {
                TaskBoardExecutionPhase::Implementation => "implementation:1".into(),
                TaskBoardExecutionPhase::Review => "review:security".into(),
                TaskBoardExecutionPhase::Evaluate => "evaluate:1".into(),
                _ => unreachable!(),
            },
            attempt: 1,
            idempotency_key: "remote-attempt-1".into(),
            host_id: "executor-a".into(),
            host_instance_id: "instance-a".into(),
            fencing_epoch: 1,
            configuration_revision: 1,
            execution_record_sha256: DIGEST.into(),
            repository: "org/repo".into(),
            base_revision: REVISION.into(),
            expected_head_revision,
        },
        lease_seconds: 60,
        deadline_at: "2026-07-20T12:00:00Z".into(),
        launch: test_codex_launch(
            phase,
            "execution-1",
            match phase {
                TaskBoardExecutionPhase::Implementation => "implementation:1",
                TaskBoardExecutionPhase::Review => "review:security",
                TaskBoardExecutionPhase::Evaluate => "evaluate:1",
                _ => unreachable!(),
            },
            "Run the exact remote phase",
        ),
        source: RemoteSourceMaterial::repository_revision("org/repo", REVISION),
        artifacts: RemoteArtifactManifest::default(),
        request_sha256: String::new(),
    }
}

fn git(directory: &std::path::Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(directory)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("utf8 git output")
        .trim()
        .to_string()
}

#[path = "task_board_remote_executor_loop/source_bundle_tests.rs"]
mod source_bundle_tests;
#[path = "task_board_remote_executor_loop/source_snapshot_tests.rs"]
mod source_snapshot_tests;
