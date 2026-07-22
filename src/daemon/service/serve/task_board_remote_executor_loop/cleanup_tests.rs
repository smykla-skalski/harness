use std::path::{Path, PathBuf};

use sqlx::query_scalar;

use crate::daemon::db::{
    REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorIdentity, TaskBoardRemoteMutationOutcome, accept_remote_executor,
    remote_executor_claim_request, remote_executor_fixture, remote_executor_identity,
};
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteSettledRequest, RemoteSourceMaterial,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome,
};

pub(super) const CLAIMED_AT: &str = "2026-07-19T10:00:10Z";
pub(super) const STARTED_AT: &str = "2026-07-19T10:00:20Z";
pub(super) const UNKNOWN_AT: &str = "2026-07-19T10:00:30Z";
pub(super) const SETTLED_AT: &str = "2026-07-19T10:00:40Z";

#[tokio::test]
async fn settled_unknown_cleanup_releases_capacity_and_survives_restart() {
    let xdg = tempfile::tempdir().expect("create isolated data root");
    let xdg_value = xdg.path().to_string_lossy().into_owned();
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_value.as_str())),
            ("CLAUDE_SESSION_ID", Some("remote-cleanup-test")),
        ],
        Box::pin(async {
            let (fixture, started, identity, workspace) = started_executor().await;
            let mut run = fixture
                .db
                .codex_run(&identity.run_id)
                .await
                .expect("load executor run")
                .expect("executor run");
            run.status = CodexRunStatus::Cancelled;
            run.updated_at = UNKNOWN_AT.into();
            fixture
                .db
                .save_codex_run(&run)
                .await
                .expect("persist stopped executor run");
            let unknown = mark_and_settle_unknown(&fixture, &started).await;
            assert_eq!(active_count(&fixture).await, 1);
            assert!(workspace.exists());

            let state = super::super::disabled_tests::executor_state(&fixture.db, "instance-a");
            super::super::reconcile_remote_executor_assignment(
                &state,
                &fixture.db,
                &unknown.assignment_id,
            )
            .await
            .expect("complete executor cleanup");
            let cleaned = fixture
                .db
                .task_board_remote_assignment(&unknown.assignment_id)
                .await
                .expect("load cleaned assignment")
                .expect("cleaned assignment");
            assert_eq!(active_count(&fixture).await, 0);
            assert!(cleaned.cleanup_completed_at.is_some());
            assert!(
                fixture
                    .db
                    .codex_run(&identity.run_id)
                    .await
                    .unwrap()
                    .is_none()
            );
            assert!(
                fixture
                    .db
                    .task_board_remote_settlement_receipt(&unknown.assignment_id)
                    .await
                    .expect("load retained settlement receipt")
                    .is_some()
            );
            assert!(!workspace.exists());

            let database_path = fixture._temp.path().join("executor.db");
            let marker = cleaned.cleanup_completed_at.clone();
            let RemoteExecutorFixture { db, _temp, .. } = fixture;
            drop(db);
            let reopened = crate::daemon::db::AsyncDaemonDb::connect(&database_path)
                .await
                .expect("reopen executor database");
            let replay = reopened
                .task_board_remote_assignment(&unknown.assignment_id)
                .await
                .expect("load cleanup after restart")
                .expect("cleanup after restart");
            assert_eq!(replay.cleanup_completed_at, marker);
            assert!(
                reopened
                    .task_board_remote_settlement_receipt(&unknown.assignment_id)
                    .await
                    .expect("load settlement receipt after restart")
                    .is_some()
            );
        }),
    )
    .await;
}

async fn mark_and_settle_unknown(
    fixture: &RemoteExecutorFixture,
    started: &TaskBoardRemoteAssignmentRecord,
) -> TaskBoardRemoteAssignmentRecord {
    let offer = started.require_offer().expect("strict executor offer");
    let TaskBoardRemoteMutationOutcome::Updated(unknown) = fixture
        .db
        .mark_task_board_remote_assignment_unknown(
            &offer.binding,
            "remote outcome requires settlement",
            UNKNOWN_AT,
        )
        .await
        .expect("mark executor assignment unknown")
    else {
        panic!("executor assignment did not become unknown");
    };
    let settlement = unknown_settlement(&unknown);
    fixture
        .db
        .settle_task_board_remote_assignment(&settlement, REMOTE_EXECUTOR_PRINCIPAL, SETTLED_AT)
        .await
        .expect("persist immutable settlement receipt");
    unknown
}

#[tokio::test]
async fn settled_completed_cleanup_preserves_terminal_artifacts() {
    let xdg = tempfile::tempdir().expect("create isolated data root");
    let xdg_value = xdg.path().to_string_lossy().into_owned();
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_value.as_str())),
            ("CLAUDE_SESSION_ID", Some("remote-artifact-cleanup-test")),
        ],
        async {
            let (fixture, started, identity, workspace) = started_executor().await;
            let mut run = fixture
                .db
                .codex_run(&identity.run_id)
                .await
                .expect("load executor run")
                .expect("executor run");
            run.status = CodexRunStatus::Completed;
            run.final_message = Some(
                serde_json::to_string(&review_result(&started))
                    .expect("serialize remote review result"),
            );
            run.updated_at = UNKNOWN_AT.into();
            fixture
                .db
                .save_codex_run(&run)
                .await
                .expect("persist completed executor run");
            super::super::terminal::persist_terminal_snapshot(
                &fixture.db,
                "instance-a",
                &started,
                &run,
                &workspace,
            )
            .await
            .expect("persist executor terminal result");
            let completed = fixture
                .db
                .task_board_remote_assignment(&started.assignment_id)
                .await
                .expect("load completed assignment")
                .expect("completed assignment");
            let settlement = completed_settlement(&completed);
            fixture
                .db
                .settle_task_board_remote_assignment(
                    &settlement,
                    REMOTE_EXECUTOR_PRINCIPAL,
                    &crate::workspace::utc_now(),
                )
                .await
                .expect("persist completed settlement");
            let artifacts_before = artifact_count(&fixture, &completed.assignment_id).await;
            assert_eq!(artifacts_before, 1);
            let scan = fixture
                .db
                .scan_task_board_remote_executor_assignments()
                .await
                .expect("scan settled completed executor assignment");
            assert!(
                scan.terminal_assignment_ids
                    .iter()
                    .any(|assignment_id| assignment_id == &completed.assignment_id)
            );

            let state = super::super::disabled_tests::executor_state(&fixture.db, "instance-a");
            super::super::reconcile_remote_executor_assignment(
                &state,
                &fixture.db,
                &completed.assignment_id,
            )
            .await
            .expect("complete settled artifact cleanup");
            assert_eq!(
                artifact_count(&fixture, &completed.assignment_id).await,
                artifacts_before
            );
            assert!(
                fixture
                    .db
                    .task_board_remote_settlement_receipt(&completed.assignment_id)
                    .await
                    .expect("load retained completed receipt")
                    .is_some()
            );
            assert!(!workspace.exists());
        },
    )
    .await;
}

async fn started_executor() -> (
    RemoteExecutorFixture,
    TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorIdentity,
    PathBuf,
) {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    // Session provisioning canonicalizes origin_path, so the frozen checkout must
    // resolve macOS /var -> /private/var or exact_provisioned_session never matches.
    super::super::disabled_tests::configure_checkout(&fixture.db, &origin).await;
    let mut request = fixture.request.clone();
    request.binding.base_revision.clone_from(&revision);
    request.binding.expected_head_revision = Some(revision.clone());
    request.source = RemoteSourceMaterial::repository_revision("example/harness", &revision);
    request.request_sha256.clear();
    let request = request.seal().expect("seal exact executor offer");
    let accepted = accept_remote_executor(&fixture, &request).await;
    fixture
        .db
        .claim_task_board_remote_assignment(
            &remote_executor_claim_request(&request, &accepted),
            REMOTE_EXECUTOR_PRINCIPAL,
            CLAIMED_AT,
        )
        .await
        .expect("claim executor assignment");
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            "instance-a",
            STARTED_AT,
        )
        .await
        .expect("claim executor start authority")
        .expect("executor start authority");
    let authorized = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load authorized assignment")
        .expect("authorized assignment");
    let identity = remote_executor_identity(&authorized).expect("executor identity");
    let workspace = super::super::source::ensure_remote_session(
        &fixture.db,
        &authorized,
        &identity,
        &revision,
        true,
        true,
    )
    .await
    .expect("create exact executor session");
    let permit = fixture
        .db
        .claim_task_board_remote_executor_start_io_permit(&authority, &workspace, STARTED_AT)
        .await
        .expect("claim exact Start I/O permit")
        .expect_acquired("Start I/O remains permitted");
    persist_run(&fixture, &authorized, &identity, &workspace).await;
    let TaskBoardRemoteMutationOutcome::Updated(started) = fixture
        .db
        .adopt_task_board_remote_executor_start(&permit, &workspace, STARTED_AT)
        .await
        .expect("adopt executor start")
    else {
        panic!("executor start did not update assignment");
    };
    (fixture, started, identity, workspace)
}

async fn persist_run(
    fixture: &RemoteExecutorFixture,
    assignment: &TaskBoardRemoteAssignmentRecord,
    identity: &TaskBoardRemoteExecutorIdentity,
    workspace: &Path,
) {
    let request = assignment
        .require_offer()
        .expect("strict offer")
        .launch
        .codex_request();
    fixture
        .db
        .save_codex_run(&CodexRunSnapshot {
            run_id: identity.run_id.clone(),
            session_id: identity.session_id.clone(),
            task_id: request.task_id,
            board_item_id: request.board_item_id,
            workflow_execution_id: request.workflow_execution_id,
            session_agent_id: None,
            display_name: request.name,
            project_dir: workspace.to_string_lossy().into_owned(),
            thread_id: request.resume_thread_id,
            turn_id: None,
            mode: request.mode,
            status: CodexRunStatus::Running,
            prompt: request.prompt,
            latest_summary: None,
            final_message: None,
            error: None,
            pending_approvals: Vec::new(),
            resolved_approvals: Vec::new(),
            events: Vec::new(),
            created_at: STARTED_AT.into(),
            updated_at: STARTED_AT.into(),
            model: request.model,
            effort: request.effort,
        })
        .await
        .expect("persist executor run");
}

fn unknown_settlement(record: &TaskBoardRemoteAssignmentRecord) -> RemoteSettledRequest {
    let offer = record.require_offer().expect("strict offer");
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record.lease_id.clone().expect("settlement lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Unknown,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal unknown settlement")
}

fn completed_settlement(record: &TaskBoardRemoteAssignmentRecord) -> RemoteSettledRequest {
    let offer = record.require_offer().expect("strict offer");
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record.lease_id.clone().expect("settlement lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Completed,
        result_sha256: record.result_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal completed settlement")
}

fn review_result(record: &TaskBoardRemoteAssignmentRecord) -> TaskBoardLocalAttemptResult {
    let binding = &record.require_offer().expect("strict offer").binding;
    let head = binding
        .expected_head_revision
        .clone()
        .expect("review exact head");
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: head.clone(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: "reviewer".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: head,
                summary: "reviewed remotely".into(),
                findings: Vec::new(),
            },
        }),
    }
}

pub(super) async fn active_count(fixture: &RemoteExecutorFixture) -> u32 {
    fixture
        .db
        .task_board_remote_executor_active_assignment_count("executor-a")
        .await
        .expect("count active executor assignments")
}

async fn artifact_count(fixture: &RemoteExecutorFixture, assignment_id: &str) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_artifacts WHERE assignment_id = ?1")
        .bind(assignment_id)
        .fetch_one(fixture.db.pool())
        .await
        .expect("count retained remote artifacts")
}

pub(super) fn git_repository(root: &Path) -> (PathBuf, String) {
    let origin = root.join("source");
    fs_err::create_dir_all(&origin).expect("create source repository");
    git(&origin, &["init", "-q"]);
    git(&origin, &["config", "user.name", "Harness Test"]);
    git(&origin, &["config", "user.email", "harness@example.com"]);
    fs_err::write(origin.join("source.txt"), "source\n").expect("write source");
    git(&origin, &["add", "source.txt"]);
    git(&origin, &["commit", "-qm", "source"]);
    let revision = git(&origin, &["rev-parse", "HEAD"]);
    (origin, revision)
}

fn git(directory: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
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
        .expect("git output utf8")
        .trim()
        .to_string()
}
