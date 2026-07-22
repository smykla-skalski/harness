use std::path::{Path, PathBuf};

use crate::daemon::db::{
    REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorIdentity, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorStopAuthority, TaskBoardRemoteExecutorStopReason,
    TaskBoardRemoteMutationOutcome, accept_remote_executor, remote_executor_claim_request,
    remote_executor_fixture, remote_executor_identity,
};
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease, RemoteSettledRequest,
    RemoteSourceMaterial, RemoteStatusResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{TaskBoardFailureClass, TaskBoardRemoteAssignmentState};

use super::super::disabled_tests::executor_state;
use super::super::source::ensure_remote_session;
use super::super::reconcile_remote_executor_assignment;
use super::tests::{
    CLAIMED_AT, SETTLED_AT, STARTED_AT, UNKNOWN_AT, active_count, git_repository,
};

const EXPIRED_AT: &str = "2026-07-19T10:11:00Z";

#[test]
fn invalid_unadopted_run_cleans_after_exact_stop_and_settlement() {
    run_deep_cleanup_async(invalid_unadopted_run_cleans_after_exact_stop_and_settlement_body);
}

async fn invalid_unadopted_run_cleans_after_exact_stop_and_settlement_body() {
    with_isolated_sessions(
        "remote-unadopted-stop-cleanup",
        async {
            let (fixture, claimed, authority, identity, workspace) =
                claimed_executor_workspace().await;
            let permit = fixture
                .db
                .claim_task_board_remote_executor_start_io_permit(
                    &authority,
                    &workspace,
                    STARTED_AT,
                )
                .await
                .expect("claim exact Start I/O permit")
                .expect_acquired("Start I/O remains permitted");
            let mut invalid = run_snapshot(&claimed, &authority, &workspace);
            invalid.prompt = "mismatched executor launch".into();
            invalid.status = CodexRunStatus::Cancelled;
            invalid.updated_at = UNKNOWN_AT.into();
            fixture
                .db
                .save_codex_run(&invalid)
                .await
                .expect("persist invalid stopped executor run");
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
                panic!("stopped run did not become unknown");
            };
            settle_unknown(&fixture, &unknown).await;
            assert_eq!(active_count(&fixture).await, 1);

            reconcile_remote_executor_assignment(
                &executor_state(&fixture.db, "successor-instance"),
                &fixture.db,
                &unknown.assignment_id,
            )
            .await
            .expect("clean stopped unadopted run");

            let cleaned = load_assignment(&fixture, &unknown.assignment_id).await;
            assert_eq!(cleaned.state, TaskBoardRemoteAssignmentState::Unknown);
            assert!(cleaned.cleanup_completed_at.is_some());
            assert_eq!(active_count(&fixture).await, 0);
            assert!(fixture.db.codex_run(&identity.run_id).await.unwrap().is_none());
            assert!(!workspace.exists());
            assert!(
                fixture
                    .db
                    .task_board_remote_settlement_receipt(&unknown.assignment_id)
                    .await
                    .expect("load immutable settlement receipt")
                    .is_some()
            );
        },
    )
    .await;
}

#[test]
fn crash_after_session_files_before_db_row_cleans_exact_orphan() {
    run_deep_cleanup_async(crash_after_session_files_before_db_row_cleans_exact_orphan_body);
}

async fn crash_after_session_files_before_db_row_cleans_exact_orphan_body() {
    with_isolated_sessions(
        "remote-orphan-session-cleanup",
        async {
            let (fixture, claimed, authority, identity, workspace) =
                claimed_executor_workspace().await;
            assert!(workspace.exists());
            assert!(
                fixture
                    .db
                    .delete_session_row(&identity.session_id)
                    .await
                    .expect("remove crash-gap session row")
            );
            let TaskBoardRemoteMutationOutcome::Updated(unknown) = fixture
                .db
                .expire_task_board_remote_executor_start_without_run(
                    &authority,
                    super::super::REMOTE_START_EXPIRED_REASON,
                    EXPIRED_AT,
                )
                .await
                .expect("expire token with no durable run")
            else {
                panic!("token-owned crash gap did not expire");
            };
            assert_eq!(claimed.assignment_id, unknown.assignment_id);
            settle_unknown(&fixture, &unknown).await;
            assert_eq!(active_count(&fixture).await, 1);

            reconcile_remote_executor_assignment(
                &executor_state(&fixture.db, "restarted-instance"),
                &fixture.db,
                &unknown.assignment_id,
            )
            .await
            .expect("clean exact orphaned session tree");

            let cleaned = load_assignment(&fixture, &unknown.assignment_id).await;
            assert!(cleaned.cleanup_completed_at.is_some());
            assert_eq!(active_count(&fixture).await, 0);
            assert!(!workspace.exists());
            assert!(
                fixture
                    .db
                    .resolve_session(&identity.session_id)
                    .await
                    .expect("reload orphaned session")
                    .is_none()
            );
        },
    )
    .await;
}

#[tokio::test]
async fn preclaim_superseded_cleanup_is_restart_safe_and_mutation_free() {
    let fixture = remote_executor_fixture(1).await;
    let accepted = accept_remote_executor(&fixture, &fixture.request).await;
    let TaskBoardRemoteMutationOutcome::Updated(superseded) = fixture
        .db
        .supersede_unclaimed_task_board_remote_assignment(
            &fixture.request.binding,
            "offer expired before claim",
            CLAIMED_AT,
        )
        .await
        .expect("supersede exact unclaimed offer")
    else {
        panic!("unclaimed offer did not become superseded");
    };
    assert_eq!(accepted.assignment_id, superseded.assignment_id);
    assert!(superseded.claimed_at.is_none());
    assert!(superseded.claim_receipt.is_none());
    assert_eq!(active_count(&fixture).await, 0);
    let identity = remote_executor_identity(&superseded).expect("preclaim executor identity");
    let settlement = terminal_settlement(
        &superseded,
        RemoteAssignmentWireState::Superseded,
    );
    let database_path = fixture._temp.path().join("executor.db");
    let RemoteExecutorFixture { db, _temp, .. } = fixture;
    drop(db);
    let reopened = crate::daemon::db::AsyncDaemonDb::connect(&database_path)
        .await
        .expect("reopen before preclaim settlement");
    reopened
        .settle_task_board_remote_assignment(
            &settlement,
            REMOTE_EXECUTOR_PRINCIPAL,
            SETTLED_AT,
        )
        .await
        .expect("settle exact preclaim generation");

    reconcile_remote_executor_assignment(
        &executor_state(&reopened, "restarted-instance"),
        &reopened,
        &superseded.assignment_id,
    )
    .await
    .expect("complete no-op preclaim cleanup");
    let cleaned = reopened
        .task_board_remote_assignment(&superseded.assignment_id)
        .await
        .expect("load cleaned preclaim generation")
        .expect("cleaned preclaim generation");
    let marker = cleaned
        .cleanup_completed_at
        .clone()
        .expect("durable preclaim cleanup marker");
    assert!(
        reopened
            .resolve_session(&identity.session_id)
            .await
            .unwrap()
            .is_none()
    );

    reconcile_remote_executor_assignment(
        &executor_state(&reopened, "another-instance"),
        &reopened,
        &superseded.assignment_id,
    )
    .await
    .expect("replay no-op preclaim cleanup");
    let replayed = reopened
        .task_board_remote_assignment(&superseded.assignment_id)
        .await
        .expect("reload preclaim cleanup")
        .expect("replayed preclaim cleanup");
    assert_eq!(replayed.cleanup_completed_at.as_deref(), Some(marker.as_str()));
    assert!(reopened.codex_run(&identity.run_id).await.unwrap().is_none());
}

#[test]
fn non_codex_no_run_start_failure_settles_failed_at_claimed() {
    run_deep_cleanup_async(non_codex_no_run_start_failure_settles_failed_at_claimed_body);
}

async fn non_codex_no_run_start_failure_settles_failed_at_claimed_body() {
    with_isolated_sessions("remote-sandbox-no-run-failure", async {
        let (fixture, claimed, authority, identity, workspace) = claimed_executor_workspace().await;
        let permit = fixture
            .db
            .claim_task_board_remote_executor_start_io_permit(&authority, &workspace, STARTED_AT)
            .await
            .expect("claim exact Start I/O permit")
            .expect_acquired("Start I/O remains permitted");
        // No run is persisted, so this is a proven no-run failure for a code other
        // than the transient preflight sentinel - it must still settle, not stick.
        let response =
            failed_at_claimed_status(&claimed, "SANDBOX001", TaskBoardFailureClass::Permanent);
        let TaskBoardRemoteMutationOutcome::Updated(failed) = fixture
            .db
            .fail_task_board_remote_executor_start_without_run(&permit, &response)
            .await
            .expect("seal a non-preflight no-run Start failure")
        else {
            panic!("non-preflight no-run Start failure did not settle Failed");
        };
        assert_eq!(failed.state, TaskBoardRemoteAssignmentState::Failed);
        assert_eq!(failed.error.as_deref(), Some("SANDBOX001"));
        assert_eq!(
            failed.status_response.and_then(|status| status.failure_class),
            Some(TaskBoardFailureClass::Permanent)
        );
        assert!(fixture.db.codex_run(&identity.run_id).await.unwrap().is_none());
    })
    .await;
}

pub(super) fn failed_at_claimed_status(
    record: &TaskBoardRemoteAssignmentRecord,
    error_code: &str,
    failure_class: TaskBoardFailureClass,
) -> RemoteStatusResponse {
    let offer = record.require_offer().expect("strict offer");
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: record.lease_id.clone().expect("lease"),
            expires_at: record.lease_expires_at.clone().expect("lease expiry"),
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: record.claimed_at.clone(),
        started_at: None,
        workspace_ref: None,
        error_code: Some(error_code.into()),
        failure_class: Some(failure_class),
        observed_at: UNKNOWN_AT.into(),
    }
    .seal()
    .expect("seal failed-at-claimed status")
}

pub(super) async fn claimed_executor_workspace() -> (
    RemoteExecutorFixture,
    TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorIdentity,
    PathBuf,
) {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture, &origin).await;
    let mut request = fixture.request.clone();
    request.binding.base_revision.clone_from(&revision);
    request.binding.expected_head_revision = Some(revision.clone());
    request.source = RemoteSourceMaterial::repository_revision("example/harness", &revision);
    request.request_sha256.clear();
    let request = request.seal().expect("seal exact cleanup offer");
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
        .expect("claim start authority")
        .expect("start authority");
    let claimed = load_assignment(&fixture, &accepted.assignment_id).await;
    let identity = remote_executor_identity(&claimed).expect("executor identity");
    let workspace = ensure_remote_session(
        &fixture.db,
        &claimed,
        &identity,
        &revision,
        true,
        true,
    )
    .await
    .expect("create exact executor session");
    (fixture, claimed, authority, identity, workspace)
}

async fn configure_checkout(fixture: &RemoteExecutorFixture, origin: &Path) {
    // Session provisioning canonicalizes origin_path, so resolve macOS
    // /var -> /private/var or exact_provisioned_session never matches.
    let origin = origin.canonicalize().unwrap_or_else(|_| origin.to_path_buf());
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.repositories[0].checkout_path =
        origin.to_string_lossy().into_owned();
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure executor checkout");
}

fn run_snapshot(
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    workspace: &Path,
) -> CodexRunSnapshot {
    let request = assignment
        .require_offer()
        .expect("strict offer")
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
    }
}

async fn settle_unknown(
    fixture: &RemoteExecutorFixture,
    record: &TaskBoardRemoteAssignmentRecord,
) {
    let request = terminal_settlement(record, RemoteAssignmentWireState::Unknown);
    fixture
        .db
        .settle_task_board_remote_assignment(
            &request,
            REMOTE_EXECUTOR_PRINCIPAL,
            SETTLED_AT,
        )
        .await
        .expect("persist immutable unknown settlement");
}

pub(super) fn terminal_settlement(
    record: &TaskBoardRemoteAssignmentRecord,
    terminal_state: RemoteAssignmentWireState,
) -> RemoteSettledRequest {
    let offer = record.require_offer().expect("strict settlement offer");
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record.lease_id.clone().expect("settlement lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state,
        result_sha256: None,
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal exact terminal settlement")
}

pub(super) async fn load_assignment(
    fixture: &RemoteExecutorFixture,
    assignment_id: &str,
) -> TaskBoardRemoteAssignmentRecord {
    fixture
        .db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load remote assignment")
        .expect("remote assignment exists")
}

/// The settled-cleanup chain (reconcile -> settle -> cleanup_executor_session ->
/// destroy_executor_session) nests a future too deep for the default libtest
/// stack in debug builds, so these cases drive it off a 32 MiB thread. Built
/// inside the thread so `temp_env` isolation need not be `Send`.
pub(super) fn run_deep_cleanup_async<F>(build: impl FnOnce() -> F + Send + 'static)
where
    F: std::future::Future<Output = ()>,
{
    std::thread::Builder::new()
        .stack_size(32 * 1024 * 1024)
        .spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build deep-cleanup test runtime")
                .block_on(build());
        })
        .expect("spawn deep-cleanup test thread")
        .join()
        .expect("join deep-cleanup test thread");
}

pub(super) async fn with_isolated_sessions<F>(session_id: &str, future: F)
where
    F: std::future::Future<Output = ()>,
{
    let data = tempfile::tempdir().expect("create isolated data root");
    let data = data.path().to_string_lossy().into_owned();
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(data.as_str())),
            ("CLAUDE_SESSION_ID", Some(session_id)),
        ],
        future,
    )
    .await;
}
