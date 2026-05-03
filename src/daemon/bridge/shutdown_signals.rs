//! POSIX signal handling for the host bridge.
//!
//! Default Rust process exit on signal skips drop chains, leaving the
//! spawned codex `app-server` orphaned to launchd and pinning the
//! listening port. This module installs a dedicated handler thread for
//! `SIGTERM`, `SIGINT`, and `SIGHUP` that flips the bridge shutdown flag,
//! runs `BridgeServer::cleanup` (which `killpg`s the codex process group),
//! and then exits the process so subsequent `bridge start` invocations
//! see a free port.

use std::fs;
use std::io::ErrorKind;
use std::process::exit;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread;

use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use signal_hook::iterator::Signals;

use crate::errors::{CliError, CliErrorKind};

use super::bridge_state::clear_bridge_state;
use super::server::BridgeServer;

/// Spawn the signal-handling thread.
///
/// The thread blocks on the signal iterator. On the first delivery it
/// performs cleanup (codex process-group kill, ACP shutdown, persisted
/// state clear) and then calls `std::process::exit(128 + signo)` so the
/// shell sees the conventional terminated-by-signal status.
pub(super) fn install(server: Arc<BridgeServer>) -> Result<(), CliError> {
    let mut signals = Signals::new([SIGTERM, SIGINT, SIGHUP]).map_err(|error| {
        CliErrorKind::workflow_io(format!("install bridge signal handlers: {error}"))
    })?;
    thread::Builder::new()
        .name("bridge-signals".to_string())
        .spawn(move || {
            if let Some(signal) = signals.forever().next() {
                handle_signal(&server, signal);
            }
        })
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn bridge signal thread: {error}"))
        })?;
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn handle_signal(server: &Arc<BridgeServer>, signal: i32) {
    tracing::info!(signal, "bridge received shutdown signal; running cleanup");
    server.shutdown.store(true, Ordering::SeqCst);
    server.cleanup();
    if let Err(error) = clear_bridge_state() {
        tracing::warn!(%error, "clear bridge state during signal shutdown");
    }
    if let Err(error) = fs::remove_file(&server.socket_path)
        && error.kind() != ErrorKind::NotFound
    {
        tracing::warn!(
            path = %server.socket_path.display(),
            %error,
            "unlink bridge socket during signal shutdown"
        );
    }
    let exit_code = 128_i32.saturating_add(signal);
    exit(exit_code);
}
