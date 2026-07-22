use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;

use axum::serve::Listener;
use tempfile::tempdir;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio_rustls::{TlsAcceptor, server::TlsStream};

use super::{test_http_state_with_db_path, with_test_remote_tls_root};
use crate::daemon::http::{DaemonHttpAuthMode, DaemonHttpState};
use crate::daemon::remote::{RemoteAccessScope, RemoteRole};
use crate::daemon::remote_identity::RemoteClientRegistration;
use crate::daemon::task_board_remote_transport::controller::RemoteExecutionControllerClient;
use crate::daemon::task_board_remote_transport::controller_authority_test_support::{
    remote_host_config, test_tls_material,
};
use crate::task_board::{
    TaskBoardLocalExecutionHostConfig, TaskBoardLocalExecutionRepositoryConfig,
    TaskBoardPhaseCapabilityProfile,
};

const HOST_ID: &str = "executor-a";
const HOST_INSTANCE: &str = "executor-acceptance-a";
const SUCCESSOR_HOST_INSTANCE: &str = "executor-acceptance-b";
const TOKEN_ENV: &str = "HARNESS_REMOTE_ACCEPTANCE_TOKEN";
const TOKEN: &str = "remote-acceptance-token-abcdefghijklmnopqrstuvwxyz";
const REPOSITORY: &str = "example/harness";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_controller_client_reaches_authenticated_executor_router() {
    let tls = test_tls_material();
    with_test_remote_tls_root(tls.ca_der(), &[(TOKEN_ENV, TOKEN)], async {
        let executor_dir = tempdir().expect("executor tempdir");
        let controller_dir = tempdir().expect("controller tempdir");
        let executor_path = executor_dir.path().join("executor.db");
        let controller_path = controller_dir.path().join("controller.db");
        let executor = configured_executor_state(&executor_path, HOST_INSTANCE, true).await;
        let server = TlsRouterServer::start(executor, tls.server_config()).await;
        let controller = test_http_state_with_db_path(&controller_path, "controller-acceptance-a");
        let controller_db = controller.async_db.get().expect("controller async db");
        let mut settings = controller_db
            .task_board_orchestrator_settings()
            .await
            .expect("load controller settings");
        settings.execution_hosts = vec![remote_host_config(
            server.endpoint(),
            &tls,
            &format!("env://{TOKEN_ENV}"),
            true,
        )];
        controller_db
            .replace_task_board_orchestrator_settings(&settings)
            .await
            .expect("configure controller host");

        let trust = controller_db
            .task_board_remote_host_trust_fence(HOST_ID)
            .await
            .expect("load controller trust");
        assert_eq!(trust.config.certificate_fingerprint, tls.spki_pin());
        {
            let client = RemoteExecutionControllerClient::connect(&trust)
                .expect("construct production controller client");
            let observed = client
                .refresh_observation(controller_db)
                .await
                .expect("authenticate and refresh executor advertisement");
            assert_eq!(observed.config.host_id, HOST_ID);
            assert_eq!(observed.advertisement.host_instance_id, HOST_INSTANCE);
        }
        let address = server.address();
        server.stop().await;
        let successor =
            configured_executor_state(&executor_path, SUCCESSOR_HOST_INSTANCE, false).await;
        let server = TlsRouterServer::start_at(address, successor, tls.server_config()).await;
        let trust = controller_db
            .task_board_remote_host_trust_fence(HOST_ID)
            .await
            .expect("reload controller trust after executor restart");
        assert_eq!(trust.config.certificate_fingerprint, tls.spki_pin());
        {
            let client = RemoteExecutionControllerClient::connect(&trust)
                .expect("construct successor production controller client");
            let observed = client
                .refresh_observation(controller_db)
                .await
                .expect("authenticate against restarted executor router");
            assert_eq!(
                observed.advertisement.host_instance_id,
                SUCCESSOR_HOST_INSTANCE
            );
        }
        server.stop().await;
    })
    .await;
}

async fn configured_executor_state(
    path: &std::path::Path,
    daemon_epoch: &str,
    register_client: bool,
) -> DaemonHttpState {
    let mut state = test_http_state_with_db_path(path, daemon_epoch);
    state.auth_mode = DaemonHttpAuthMode::Remote;
    if register_client {
        register_execution_coordinator(&state);
    }
    let db = state.async_db.get().expect("executor async db");
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
            checkout_path: path
                .parent()
                .expect("executor database parent")
                .join("checkouts")
                .to_string_lossy()
                .into_owned(),
        }],
        runtimes: vec!["codex".into()],
        capabilities: vec![
            TaskBoardPhaseCapabilityProfile::ImplementationWrite,
            TaskBoardPhaseCapabilityProfile::ReviewReadOnly,
            TaskBoardPhaseCapabilityProfile::EvaluateReadOnly,
        ],
    };
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure executor host");
    state
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
        .expect("executor sync db")
        .lock()
        .expect("executor sync db lock")
        .register_remote_client(&registration)
        .expect("register execution coordinator");
}

struct TlsRouterServer {
    address: SocketAddr,
    endpoint: String,
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<()>,
}

impl TlsRouterServer {
    async fn start(state: DaemonHttpState, server: Arc<rustls::ServerConfig>) -> Self {
        Self::start_at(
            "127.0.0.1:0".parse().expect("loopback address"),
            state,
            server,
        )
        .await
    }

    async fn start_at(
        address: SocketAddr,
        state: DaemonHttpState,
        server: Arc<rustls::ServerConfig>,
    ) -> Self {
        let listener = TcpListener::bind(address)
            .await
            .expect("bind executor TLS listener");
        let address = listener.local_addr().expect("executor TLS address");
        let (shutdown, shutdown_rx) = oneshot::channel();
        let app = super::super::super::daemon_http_router(state);
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
            address,
            endpoint: format!("https://localhost:{}", address.port()),
            shutdown,
            task,
        }
    }

    fn endpoint(&self) -> &str {
        &self.endpoint
    }

    fn address(&self) -> SocketAddr {
        self.address
    }

    async fn stop(self) {
        let _ = self.shutdown.send(());
        self.task.await.expect("join executor TLS router");
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
