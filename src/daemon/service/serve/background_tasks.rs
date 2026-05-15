use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;

use crate::daemon::http::DaemonHttpState;

use super::acp_inspect_publisher::spawn_acp_inspect_publisher;
use super::task_board_orchestrator_loop::spawn_task_board_orchestrator_loop;

pub(super) fn spawn_background_tasks(
    app_state: &DaemonHttpState,
    poll_interval: Duration,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> (JoinHandle<()>, Option<JoinHandle<()>>) {
    (
        spawn_acp_inspect_publisher(
            app_state.sender.clone(),
            shutdown_rx.clone(),
            app_state.acp_agent_manager.clone(),
        ),
        app_state.async_db.get().map(|_| {
            spawn_task_board_orchestrator_loop(app_state.clone(), poll_interval, shutdown_rx)
        }),
    )
}
