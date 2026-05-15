use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;

use crate::daemon::http::DaemonHttpState;

use super::acp_inspect_publisher::spawn_acp_inspect_publisher;
use super::machine_heartbeat_loop::spawn_machine_heartbeat_loop;
use super::task_board_orchestrator_loop::spawn_task_board_orchestrator_loop;

pub(super) struct BackgroundTaskHandles {
    pub _acp_inspect_push: JoinHandle<()>,
    pub _machine_heartbeat: JoinHandle<()>,
    pub _task_board_orchestrator_loop: Option<JoinHandle<()>>,
}

pub(super) fn spawn_background_tasks(
    app_state: &DaemonHttpState,
    poll_interval: Duration,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> BackgroundTaskHandles {
    BackgroundTaskHandles {
        _acp_inspect_push: spawn_acp_inspect_publisher(
            app_state.sender.clone(),
            shutdown_rx.clone(),
            app_state.acp_agent_manager.clone(),
        ),
        _machine_heartbeat: spawn_machine_heartbeat_loop(shutdown_rx.clone()),
        _task_board_orchestrator_loop: app_state.async_db.get().map(|_| {
            spawn_task_board_orchestrator_loop(app_state.clone(), poll_interval, shutdown_rx)
        }),
    }
}
