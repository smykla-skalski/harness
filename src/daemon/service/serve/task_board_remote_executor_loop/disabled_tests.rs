use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use chrono::{Duration, SecondsFormat, Utc};
use sqlx::query_scalar;
use tokio::sync::broadcast;

use super::{prepare_remote_workspace, reconcile_remote_executor_assignment};
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{
    AsyncDaemonDb, DaemonDb, REMOTE_EXECUTOR_CLAIMED_AT, REMOTE_EXECUTOR_PRINCIPAL,
    RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteMutationOutcome, accept_remote_executor, remote_executor_claim_request,
    remote_executor_fixture, remote_executor_identity,
};
use crate::daemon::http::{
    AsyncDaemonDbSlot, DaemonHttpAuthMode, DaemonHttpState, ManagedAgentMutationLocks,
    default_remote_pairing_limiter, default_remote_pairing_status_limiter,
};
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus, StreamEvent};
use crate::daemon::state::DaemonManifest;
use crate::daemon::task_board_remote_transport::wire::{RemoteOfferRequest, RemoteSourceMaterial};
use crate::daemon::websocket::ReplayBuffer;
use crate::task_board::TaskBoardRemoteAssignmentState;

pub(super) const EXECUTOR_INSTANCE: &str = "instance-a";
const EXECUTOR_REPOSITORY: &str = "example/harness";
pub(super) const EXECUTOR_START_AT: &str = "2026-07-19T10:00:20Z";

#[derive(Clone, Copy)]
pub(super) enum SettingsDrift {
    Disabled,
    RevisionOnly,
}

#[tokio::test]
async fn settings_winner_revokes_start_before_any_workspace_or_codex_io() {
    for drift in [SettingsDrift::Disabled, SettingsDrift::RevisionOnly] {
        let (fixture, accepted) = live_claimed_fixture().await;
        drift_executor_settings(&fixture.db, drift).await;
        let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);

        reconcile_remote_executor_assignment(&state, &fixture.db, &accepted.assignment_id)
            .await
            .expect("settings winner settles the unstarted generation without executor I/O");
        assert_eq!(codex_run_count(&fixture.db).await, 0);
        assert_eq!(executor_session_count(&fixture.db).await, 0);
        let revoked = load_assignment(&fixture.db, &accepted.assignment_id).await;
        assert_eq!(revoked.state, TaskBoardRemoteAssignmentState::Unknown);
        assert!(revoked.executor_start_authority_sha256.is_none());
        assert_eq!(
            revoked.error.as_deref(),
            Some("remote executor settings changed before worker start")
        );
    }
}

#[tokio::test]
async fn predecessor_claim_without_run_converges_unknown_without_executor_io() {
    let (fixture, accepted) = live_claimed_fixture().await;
    let state = executor_state(&fixture.db, "successor-instance");

    reconcile_remote_executor_assignment(&state, &fixture.db, &accepted.assignment_id)
        .await
        .expect("successor settles the empty predecessor claim without executor I/O");

    let unknown = load_assignment(&fixture.db, &accepted.assignment_id).await;
    assert_eq!(unknown.state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(unknown.executor_start_authority_sha256.is_none());
    assert_eq!(
        unknown.error.as_deref(),
        Some("remote executor restarted before worker start")
    );
    assert_eq!(codex_run_count(&fixture.db).await, 0);
    assert_eq!(executor_session_count(&fixture.db).await, 0);

    reconcile_remote_executor_assignment(&state, &fixture.db, &accepted.assignment_id)
        .await
        .expect("empty predecessor claim recovery replays without executor I/O");
    assert_eq!(
        load_assignment(&fixture.db, &accepted.assignment_id).await,
        unknown
    );
}

#[tokio::test]
async fn start_authority_is_durable_before_checkout_io() {
    let (fixture, accepted) = live_claimed_fixture().await;
    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);

    let error = reconcile_remote_executor_assignment(&state, &fixture.db, &accepted.assignment_id)
        .await
        .expect_err("non-repository checkout must fail after authority acquisition");
    assert!(
        error
            .to_string()
            .contains("verify remote executor Git source"),
        "unexpected checkout error: {error}"
    );
    let authorized = load_assignment(&fixture.db, &accepted.assignment_id).await;
    assert!(authorized.executor_start_authority_sha256.is_some());
    assert_eq!(codex_run_count(&fixture.db).await, 0);
    assert_eq!(executor_session_count(&fixture.db).await, 0);
}

#[tokio::test]
async fn expired_provisioning_permit_cleans_partial_workspace_before_unknown() {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture.db, &origin).await;
    let request = request_for_revision(&fixture.request, &revision);
    let (accepted, authority) = claim_start_authority(&fixture, &request).await;
    let claimed = load_assignment(&fixture.db, &accepted.assignment_id).await;
    let identity = remote_executor_identity(&claimed).expect("remote executor identity");
    let workspace = prepare_remote_workspace(
        &fixture.db,
        &claimed,
        claimed.require_offer().expect("sealed offer"),
        &identity,
        true,
    )
    .await
    .expect("persist partial executor workspace before crash");
    let session_root = workspace
        .parent()
        .expect("executor workspace has a session root")
        .to_path_buf();
    assert!(session_root.exists());
    assert_eq!(executor_session_count(&fixture.db).await, 1);

    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);
    reconcile_remote_executor_assignment(&state, &fixture.db, &accepted.assignment_id)
        .await
        .expect("restart expires only after deterministic provisioning cleanup");

    let expired = load_assignment(&fixture.db, &accepted.assignment_id).await;
    assert_eq!(expired.state, TaskBoardRemoteAssignmentState::Unknown);
    assert!(expired.executor_start_authority_sha256.is_none());
    assert_eq!(
        expired.error.as_deref(),
        Some(super::REMOTE_START_EXPIRED_REASON)
    );
    assert!(!session_root.exists());
    assert_eq!(executor_session_count(&fixture.db).await, 0);
    assert_eq!(codex_run_count(&fixture.db).await, 0);
    assert_eq!(authority.identity, identity);
    drift_executor_settings(&fixture.db, SettingsDrift::Disabled).await;
    reconcile_remote_executor_assignment(&state, &fixture.db, &accepted.assignment_id)
        .await
        .expect("expired cleanup replays without a second Start");
    assert_eq!(codex_run_count(&fixture.db).await, 0);
}

pub(super) async fn claim_start_authority(
    fixture: &RemoteExecutorFixture,
    request: &RemoteOfferRequest,
) -> (
    TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorStartAuthority,
) {
    let accepted = accept_remote_executor(fixture, request).await;
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(
                &remote_executor_claim_request(request, &accepted),
                REMOTE_EXECUTOR_PRINCIPAL,
                REMOTE_EXECUTOR_CLAIMED_AT,
            )
            .await
            .expect("claim executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            EXECUTOR_INSTANCE,
            EXECUTOR_START_AT,
        )
        .await
        .expect("claim executor start authority")
        .expect("start remains authorized");
    (accepted, authority)
}

async fn live_claimed_fixture() -> (RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord) {
    let fixture = remote_executor_fixture(1).await;
    let invalid_checkout = fixture._temp.path().join("not-a-repository");
    fs_err::create_dir_all(&invalid_checkout).expect("create non-repository checkout");
    configure_checkout(&fixture.db, &invalid_checkout).await;
    let now = Utc::now();
    let offered_at = (now - Duration::seconds(2)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let claimed_at = (now - Duration::seconds(1)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let mut request = fixture.request.clone();
    request.deadline_at =
        (now + Duration::minutes(10)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    request.request_sha256.clear();
    let request = request.seal().expect("seal live executor offer");
    let accepted = match fixture
        .db
        .accept_task_board_remote_assignment_offer(
            &request,
            REMOTE_EXECUTOR_PRINCIPAL,
            EXECUTOR_INSTANCE,
            &offered_at,
        )
        .await
        .expect("accept live executor offer")
    {
        crate::daemon::db::TaskBoardRemoteOfferOutcome::Created(record) => record,
        outcome => panic!("unexpected live offer outcome: {outcome:?}"),
    };
    fixture
        .db
        .claim_task_board_remote_assignment(
            &remote_executor_claim_request(&request, &accepted),
            REMOTE_EXECUTOR_PRINCIPAL,
            &claimed_at,
        )
        .await
        .expect("claim live executor offer");
    let claimed = load_assignment(&fixture.db, &accepted.assignment_id).await;
    (fixture, claimed)
}

pub(super) async fn drift_executor_settings(db: &AsyncDaemonDb, drift: SettingsDrift) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    if matches!(drift, SettingsDrift::Disabled) {
        settings.local_execution_host.enabled = false;
    }
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("persist executor settings drift");
}

pub(super) async fn configure_checkout(db: &AsyncDaemonDb, origin: &Path) {
    // Session provisioning canonicalizes origin_path (resolve_project_input ->
    // fs::canonicalize), so on macOS the frozen checkout must resolve the
    // /var -> /private/var symlink or exact_provisioned_session never matches.
    let origin = origin
        .canonicalize()
        .unwrap_or_else(|_| origin.to_path_buf());
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.repositories[0].checkout_path =
        origin.to_string_lossy().into_owned();
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure exact executor checkout");
}

pub(super) fn request_for_revision(
    request: &RemoteOfferRequest,
    revision: &str,
) -> RemoteOfferRequest {
    let mut request = request.clone();
    request.binding.base_revision = revision.into();
    request.binding.expected_head_revision = Some(revision.into());
    request.source = RemoteSourceMaterial::repository_revision(EXECUTOR_REPOSITORY, revision);
    request.request_sha256.clear();
    request.seal().expect("seal exact source request")
}

pub(super) async fn persist_exact_run(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    workspace: &Path,
) {
    let offer = assignment.require_offer().expect("sealed executor offer");
    let request = super::runtime::remote_codex_request(offer);
    db.save_codex_run(&CodexRunSnapshot {
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
        created_at: authority.acquired_at.clone(),
        updated_at: authority.acquired_at.clone(),
        model: request.model,
        effort: request.effort,
    })
    .await
    .expect("persist exact durable executor run");
}

pub(super) fn executor_state(db: &AsyncDaemonDb, daemon_epoch: &str) -> DaemonHttpState {
    let (sender, _) = broadcast::channel::<StreamEvent>(8);
    let db_slot = Arc::new(OnceLock::<Arc<Mutex<DaemonDb>>>::new());
    let async_db = Arc::new(OnceLock::new());
    async_db
        .set(Arc::new(db.clone()))
        .expect("install async executor db");
    DaemonHttpState {
        token: "token".into(),
        auth_mode: DaemonHttpAuthMode::Local,
        remote_domain: None,
        remote_request_limits: None,
        remote_pairing_limiter: default_remote_pairing_limiter(),
        remote_pairing_status_limiter: default_remote_pairing_status_limiter(),
        sender: sender.clone(),
        prepared_sender: broadcast::channel(8).0,
        manifest: test_manifest(),
        daemon_epoch: daemon_epoch.into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: AsyncDaemonDbSlot::from_inner(async_db.clone()),
        db_path: None,
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db.clone(),
            false,
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db.clone(),
            false,
        ),
        acp_agent_manager: AcpAgentManagerHandle::new_with_async_db(sender, db_slot, async_db),
        managed_agent_mutation_locks: ManagedAgentMutationLocks::default(),
        recovery_snapshot: Arc::default(),
    }
}

fn test_manifest() -> DaemonManifest {
    serde_json::from_value(serde_json::json!({
        "version": "49.2.0",
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": EXECUTOR_START_AT,
        "token_path": "/tmp/token",
        "sandboxed": false,
        "host_bridge": {},
        "revision": 0,
        "updated_at": "",
        "binary_stamp": null
    }))
    .expect("test daemon manifest")
}

pub(super) async fn load_assignment(
    db: &AsyncDaemonDb,
    assignment_id: &str,
) -> TaskBoardRemoteAssignmentRecord {
    db.task_board_remote_assignment(assignment_id)
        .await
        .expect("load executor assignment")
        .expect("executor assignment")
}

pub(super) async fn codex_run_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(db.pool())
        .await
        .expect("count executor Codex runs")
}

pub(super) async fn executor_session_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM sessions")
        .fetch_one(db.pool())
        .await
        .expect("count executor sessions")
}

pub(super) fn git_repository(root: &Path) -> (std::path::PathBuf, String) {
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
