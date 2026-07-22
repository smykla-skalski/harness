use std::collections::BTreeMap;
use std::future::Future;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use axum::serve::Listener;
use tempfile::TempDir;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio_rustls::{TlsAcceptor, server::TlsStream};

use super::super::test_http_state_with_db_path;
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, workflow_owner};
use crate::daemon::http::{DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;
use crate::daemon::task_board_remote_transport::controller_authority_test_support::{
    TestTlsMaterial, remote_host_config,
};
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardAttemptState,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardItem, TaskBoardLocalExecutionHostConfig,
    TaskBoardLocalExecutionRepositoryConfig, TaskBoardOrchestratorWorkflow,
    TaskBoardPhaseCapabilityProfile, TaskBoardReadOnlyRunContext,
    TaskBoardRepositoryAutomationConfig, TaskBoardStatus, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    TaskBoardWorkflowStatus, TaskBoardWorkflowTransitionState, bind_plan_approval,
    build_planning_result, resolve_task_board_reviewers,
};

pub(super) const HOST_ID: &str = "executor-a";
pub(super) const HOST_INSTANCE: &str = "executor-acceptance-a";
pub(super) const TOKEN_ENV: &str = "HARNESS_REMOTE_ACCEPTANCE_TOKEN";
pub(super) const TOKEN: &str = "remote-acceptance-token-abcdefghijklmnopqrstuvwxyz";
pub(super) const REPOSITORY: &str = "example/harness";
const SESSION_ID: &str = "remote-acceptance-session";
const EXECUTION_ID: &str = "remote-acceptance-execution";
const ITEM_ID: &str = "remote-acceptance-item";

pub(super) struct AcceptanceFixture {
    _controller_dir: TempDir,
    _executor_dir: TempDir,
    pub(super) controller_path: PathBuf,
    pub(super) executor_path: PathBuf,
    pub(super) controller_worktree: PathBuf,
    pub(super) executor_checkout: PathBuf,
}

pub(super) struct SeededExecution {
    pub(super) execution_id: String,
    pub(super) session_id: String,
    pub(super) base_revision: String,
}

impl AcceptanceFixture {
    pub(super) fn new() -> Self {
        let controller_dir = tempfile::tempdir().expect("controller acceptance tempdir");
        let executor_dir = tempfile::tempdir().expect("executor acceptance tempdir");
        let controller_worktree = controller_dir.path().join("controller-worktree");
        let executor_checkout = executor_dir.path().join("executor-checkout");
        init_repository(&controller_worktree, "controller source\n");
        git(
            &controller_worktree,
            &["branch", "-f", &format!("harness/{SESSION_ID}"), "HEAD"],
        );
        git(
            &controller_worktree,
            &["switch", "--quiet", &format!("harness/{SESSION_ID}")],
        );
        init_repository(&executor_checkout, "executor placeholder\n");
        let controller_worktree = controller_worktree
            .canonicalize()
            .expect("canonical controller worktree");
        let executor_checkout = executor_checkout
            .canonicalize()
            .expect("canonical executor checkout");
        Self {
            controller_path: controller_dir.path().join("controller.db"),
            executor_path: executor_dir.path().join("executor.db"),
            controller_worktree,
            executor_checkout,
            _controller_dir: controller_dir,
            _executor_dir: executor_dir,
        }
    }

    pub(super) fn controller_state(&self, daemon_epoch: &str) -> DaemonHttpState {
        test_http_state_with_db_path(&self.controller_path, daemon_epoch)
    }

    pub(super) async fn executor_state(
        &self,
        daemon_epoch: &str,
        initialize: bool,
    ) -> DaemonHttpState {
        let mut state = test_http_state_with_db_path(&self.executor_path, daemon_epoch);
        state.auth_mode = DaemonHttpAuthMode::Remote;
        if initialize {
            register_execution_coordinator(&state);
            configure_executor(&state, &self.executor_checkout).await;
        }
        state
    }

    pub(super) async fn configure_controller(
        &self,
        controller: &DaemonHttpState,
        endpoint: &str,
        tls: &TestTlsMaterial,
    ) {
        let db = controller
            .async_db
            .get()
            .expect("controller async database");
        let mut settings = db
            .task_board_orchestrator_settings()
            .await
            .expect("load controller settings");
        let host = remote_host_config(endpoint, tls, &format!("env://{TOKEN_ENV}"), true);
        assert_eq!(host.certificate_fingerprint, tls.spki_pin());
        settings.execution_hosts = vec![host];
        settings.repositories = vec![TaskBoardRepositoryAutomationConfig {
            repository: REPOSITORY.into(),
            enabled: true,
            workflows: vec![TaskBoardOrchestratorWorkflow::DefaultTask],
            preferred_host_id: Some(HOST_ID.into()),
            execution_checkout_path: None,
        }];
        db.replace_task_board_orchestrator_settings(&settings)
            .await
            .expect("configure controller remote host");
    }

    pub(super) async fn seed_default_task(&self, db: &AsyncDaemonDb) -> SeededExecution {
        let now = crate::workspace::utc_now();
        let base_revision = git(&self.controller_worktree, &["rev-parse", "HEAD"]);
        let mut item = TaskBoardItem::new(
            ITEM_ID.into(),
            "Remote implementation acceptance".into(),
            "Implement a committed result from the frozen source snapshot.".into(),
            now.clone(),
        );
        configure_default_task_item(&mut item);
        let item_mutation = db
            .create_task_board_item(item)
            .await
            .expect("create remote acceptance item");
        let settings = db
            .task_board_orchestrator_settings_snapshot()
            .await
            .expect("load configured controller settings");
        let reviewers = resolve_task_board_reviewers(
            &settings.settings.reviewers,
            TaskBoardWorkflowKind::DefaultTask,
            Some(REPOSITORY),
        )
        .expect("resolve default task reviewers");
        let snapshot = TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::DefaultTask,
            execution_repository: Some(REPOSITORY.into()),
            item_revision: item_mutation.item_revision,
            configuration_revision: u64::try_from(settings.row_revision)
                .expect("controller settings revision"),
            policy_version: settings.settings.policy_version,
            reviewer: reviewers.clone(),
            read_only_run_context: Some(TaskBoardReadOnlyRunContext {
                schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                session_id: SESSION_ID.into(),
                title: "Remote implementation acceptance".into(),
                body: "Implement a committed result from the frozen source snapshot.".into(),
                tags: Vec::new(),
                worktree: self.controller_worktree.to_string_lossy().into_owned(),
            }),
            provider_revision: None,
        };
        let execution = default_task_execution(snapshot, reviewers, &base_revision, &now);
        db.create_or_load_task_board_workflow_execution(&execution)
            .await
            .expect("create default task execution");
        db.create_task_board_execution_attempt(&implementation_attempt(&now))
            .await
            .expect("create remote implementation attempt");
        SeededExecution {
            execution_id: EXECUTION_ID.into(),
            session_id: SESSION_ID.into(),
            base_revision,
        }
    }
}

pub(super) async fn assignment(
    db: &AsyncDaemonDb,
    execution_id: &str,
) -> TaskBoardRemoteAssignmentRecord {
    let execution = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load remote acceptance execution")
        .expect("remote acceptance execution exists");
    let assignment_id = crate::task_board::task_board_remote_execution_target(&execution)
        .expect("remote assignment selected");
    db.task_board_remote_assignment(assignment_id)
        .await
        .expect("load remote assignment")
        .expect("remote assignment exists")
}

pub(super) fn git(path: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .expect("run test git command");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("test git output utf8")
        .trim()
        .to_owned()
}

pub(super) struct TlsRouterServer {
    endpoint: String,
    bound_address: SocketAddr,
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<()>,
}

impl TlsRouterServer {
    pub(super) async fn start(state: DaemonHttpState, server: Arc<rustls::ServerConfig>) -> Self {
        Self::start_at(
            "127.0.0.1:0".parse().expect("loopback address"),
            state,
            server,
        )
        .await
    }

    pub(super) fn endpoint(&self) -> &str {
        &self.endpoint
    }

    pub(super) fn bound_address(&self) -> SocketAddr {
        self.bound_address
    }

    pub(super) async fn stop(self) {
        let _ = self.shutdown.send(());
        self.task.await.expect("join executor TLS router");
    }

    pub(super) async fn start_at(
        address: SocketAddr,
        state: DaemonHttpState,
        server: Arc<rustls::ServerConfig>,
    ) -> Self {
        let listener = TcpListener::bind(address)
            .await
            .expect("bind executor TLS listener");
        let address = listener.local_addr().expect("executor TLS address");
        let (shutdown, shutdown_rx) = oneshot::channel();
        let app = super::super::super::super::daemon_http_router(state);
        let listener = TlsListener {
            listener,
            acceptor: TlsAcceptor::from(server),
        };
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(async move {
                    let _ = shutdown_rx.await;
                })
                .await
                .expect("serve executor TLS router");
        });
        Self {
            endpoint: format!("https://localhost:{}", address.port()),
            bound_address: address,
            shutdown,
            task,
        }
    }
}

struct TlsListener {
    listener: TcpListener,
    acceptor: TlsAcceptor,
}

impl Listener for TlsListener {
    type Io = TlsStream<TcpStream>;
    type Addr = SocketAddr;

    fn accept(&mut self) -> impl Future<Output = (Self::Io, Self::Addr)> + Send {
        async move {
            loop {
                let (stream, address) = self.listener.accept().await.expect("accept executor TCP");
                if let Ok(stream) = self.acceptor.accept(stream).await {
                    return (stream, address);
                }
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<Self::Addr> {
        self.listener.local_addr()
    }
}

async fn configure_executor(state: &DaemonHttpState, checkout: &Path) {
    let db = state.async_db.get().expect("executor async database");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host = TaskBoardLocalExecutionHostConfig {
        enabled: true,
        host_id: HOST_ID.into(),
        capacity: 1,
        repositories: vec![TaskBoardLocalExecutionRepositoryConfig {
            repository: REPOSITORY.into(),
            checkout_path: checkout.to_string_lossy().into_owned(),
        }],
        runtimes: vec!["codex".into()],
        capabilities: vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite],
    };
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure executor host");
}

fn register_execution_coordinator(state: &DaemonHttpState) {
    let registration = RemoteClientRegistration::new_for_tests(
        HOST_ID,
        "Remote Execution Acceptance",
        "test",
        RemoteRole::ExecutionCoordinator,
        &[] as &[RemoteAccessScope],
        TOKEN,
        "2026-07-22T00:00:00Z",
    )
    .expect("execution coordinator registration");
    state
        .db
        .get()
        .expect("executor sync database")
        .lock()
        .expect("executor sync database lock")
        .register_remote_client(&registration)
        .expect("register execution coordinator");
}

fn configure_default_task_item(item: &mut TaskBoardItem) {
    item.agent_mode = AgentMode::Headless;
    item.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    item.execution_repository = Some(REPOSITORY.into());
    item.session_id = Some(SESSION_ID.into());
    item.work_item_id = Some("remote-acceptance-task".into());
    item.workflow.execution_id = Some(EXECUTION_ID.into());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("implementation".into());
    item.workflow.branch = Some(format!("harness/{SESSION_ID}"));
    item.planning.summary = Some("# Plan\n\nImplement the frozen source snapshot.".into());
    item.planning.approved_by = Some("acceptance-test".into());
    item.planning.approved_at = Some(crate::workspace::utc_now());
    item.status = TaskBoardStatus::InProgress;
}

fn default_task_execution(
    snapshot: TaskBoardWorkflowSnapshot,
    reviewers: crate::task_board::TaskBoardResolvedReviewer,
    base_revision: &str,
    now: &str,
) -> TaskBoardWorkflowExecutionRecord {
    let planning_result = build_planning_result(
        "# Plan\n\nImplement the frozen source snapshot.",
        ["Commit an implementation result on the executor.".into()],
        &snapshot,
        EXECUTION_ID,
    )
    .expect("build default task plan");
    let plan_approval = bind_plan_approval(
        &planning_result,
        &snapshot,
        EXECUTION_ID,
        "acceptance-test",
        now,
    )
    .expect("bind default task approval");
    TaskBoardWorkflowExecutionRecord {
        execution_id: EXECUTION_ID.into(),
        item_id: ITEM_ID.into(),
        snapshot,
        resolved_reviewers: reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::DefaultTask,
            phase: Some(TaskBoardExecutionPhase::Implementation),
            execution_state: TaskBoardExecutionState::Preparing,
            pull_request: None,
            exact_head_revision: Some(base_revision.into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts {
            planning_result: Some(planning_result),
            plan_approval: Some(plan_approval),
            ..TaskBoardWorkflowExecutionArtifacts::default()
        },
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([
                ("admission_owner".into(), workflow_owner(EXECUTION_ID)),
                ("task_id".into(), "remote-acceptance-task".into()),
            ]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: now.into(),
        updated_at: now.into(),
        completed_at: None,
        attempts: Vec::new(),
    }
}

fn implementation_attempt(now: &str) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: EXECUTION_ID.into(),
        action_key: "implementation:1".into(),
        attempt: 1,
        idempotency_key: "remote-acceptance-implementation-1".into(),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: now.into(),
        updated_at: now.into(),
        completed_at: None,
    }
}

fn init_repository(path: &Path, content: &str) {
    std::fs::create_dir_all(path).expect("create acceptance repository");
    git(path, &["init", "-q", "-b", "main"]);
    git(path, &["config", "user.name", "Harness Acceptance"]);
    git(
        path,
        &["config", "user.email", "acceptance@harness.invalid"],
    );
    git(
        path,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/example/harness.git",
        ],
    );
    std::fs::write(path.join("source.txt"), content).expect("write acceptance source");
    git(path, &["add", "source.txt"]);
    git(path, &["commit", "-qm", "source"]);
}
