use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::broadcast;
use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;

use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::StreamEvent;
use crate::daemon::remote_pairing_expiry_loop::spawn_remote_pairing_expiry_loop;
use crate::daemon::websocket::{PreparedBroadcast, ReplayBuffer, run_broadcast_fanout};

use super::acp_inspect_publisher::spawn_acp_inspect_publisher;
use super::github_data_change_publisher::spawn_github_data_change_publisher;
use super::machine_heartbeat_loop::spawn_machine_heartbeat_loop;
use super::task_board_dispatch_loop::spawn_task_board_dispatch_loop;
use super::task_board_orchestrator_loop::spawn_task_board_orchestrator_loop;

/// Spawn the single broadcast fan-out task and return the prepared-event
/// channel that connection relays and SSE streams subscribe to. The task is the
/// sole consumer of the raw `sender`, so each event is deep-cloned and
/// serialized exactly once regardless of how many clients connect.
pub(super) fn spawn_broadcast_fanout(
    sender: &broadcast::Sender<StreamEvent>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
) -> broadcast::Sender<Arc<PreparedBroadcast>> {
    let (prepared_sender, _) = broadcast::channel(256);
    tokio::spawn(run_broadcast_fanout(
        sender.subscribe(),
        prepared_sender.clone(),
        Arc::clone(replay_buffer),
    ));
    prepared_sender
}

pub(super) struct BackgroundTaskHandles {
    pub _acp_inspect_push: JoinHandle<()>,
    pub _github_data_change_push: JoinHandle<()>,
    pub _machine_heartbeat: Option<JoinHandle<()>>,
    pub _remote_pairing_expiry: Option<JoinHandle<()>>,
    pub _task_board_dispatch_loop: Option<JoinHandle<()>>,
    pub _task_board_orchestrator_loop: Option<JoinHandle<()>>,
}

pub(super) fn spawn_background_tasks(
    app_state: &DaemonHttpState,
    poll_interval: Duration,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> BackgroundTaskHandles {
    let async_db = app_state.async_db.get().cloned();
    let remote_pairing_expiry = if app_state.auth_mode == DaemonHttpAuthMode::Remote {
        async_db
            .as_ref()
            .map(|db| spawn_remote_pairing_expiry_loop(Arc::clone(db), shutdown_rx.clone()))
    } else {
        None
    };
    BackgroundTaskHandles {
        _acp_inspect_push: spawn_acp_inspect_publisher(
            app_state.sender.clone(),
            shutdown_rx.clone(),
            app_state.acp_agent_manager.clone(),
        ),
        _github_data_change_push: spawn_github_data_change_publisher(
            app_state.sender.clone(),
            shutdown_rx.clone(),
        ),
        _machine_heartbeat: async_db
            .as_ref()
            .map(|db| spawn_machine_heartbeat_loop(Arc::clone(db), shutdown_rx.clone())),
        _remote_pairing_expiry: remote_pairing_expiry,
        _task_board_dispatch_loop: async_db
            .as_ref()
            .map(|_| spawn_task_board_dispatch_loop(app_state.clone(), shutdown_rx.clone())),
        _task_board_orchestrator_loop: async_db.map(|db| {
            spawn_task_board_orchestrator_loop(app_state.clone(), db, poll_interval, shutdown_rx)
        }),
    }
}
