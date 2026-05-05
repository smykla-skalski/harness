use std::process::Child;

#[cfg(unix)]
use std::thread;

#[cfg(unix)]
use nix::sys::signal::{Signal, killpg};
#[cfg(unix)]
use nix::unistd::Pid;
#[cfg(unix)]
use tracing::{debug, info, warn};

use crate::agents::acp::client::DAEMON_SHUTDOWN;

use super::SIGTERM_GRACE_PERIOD;

/// Kill a process group: SIGTERM, wait grace period, then SIGKILL if needed.
///
/// This is a blocking function that sleeps for `SIGTERM_GRACE_PERIOD`. Call it
/// from a dedicated thread or `spawn_blocking`, not directly from an async task.
#[cfg(unix)]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn kill_process_group(pgid: i32, child: &mut Child) {
    info!(pgid, "sending SIGTERM to process group");
    if let Err(e) = killpg(Pid::from_raw(pgid), Signal::SIGTERM) {
        warn!(pgid, error = %e, "SIGTERM to process group failed");
    }

    thread::sleep(SIGTERM_GRACE_PERIOD);

    match child.try_wait() {
        Ok(Some(status)) => {
            debug!(pgid, ?status, "process exited after SIGTERM");
        }
        Ok(None) => {
            warn!(
                pgid,
                "process did not exit within grace period; sending SIGKILL"
            );
            if let Err(e) = killpg(Pid::from_raw(pgid), Signal::SIGKILL) {
                warn!(pgid, error = %e, "SIGKILL to process group failed");
            }
            let _ = child.wait();
        }
        Err(e) => {
            warn!(pgid, error = %e, "failed to check process status; sending SIGKILL");
            if let Err(e) = killpg(Pid::from_raw(pgid), Signal::SIGKILL) {
                warn!(pgid, error = %e, "SIGKILL to process group failed");
            }
            let _ = child.wait();
        }
    }
}

#[cfg(not(unix))]
pub fn kill_process_group(_pgid: i32, child: &mut Child) {
    let _ = child.kill();
}

/// JSON-RPC error response for daemon shutdown.
#[derive(Debug, Clone)]
pub struct DaemonShutdownError {
    pub code: i32,
    pub message: String,
}

impl DaemonShutdownError {
    #[must_use]
    pub fn new() -> Self {
        Self {
            code: DAEMON_SHUTDOWN,
            message: "daemon shutdown in progress".to_string(),
        }
    }
}

impl Default for DaemonShutdownError {
    fn default() -> Self {
        Self::new()
    }
}
