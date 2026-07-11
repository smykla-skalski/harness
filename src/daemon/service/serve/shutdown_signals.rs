use std::process::{exit, id as process_id};
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};

use signal_hook::consts::{SIGHUP, SIGINT, SIGPIPE, SIGTERM};
use signal_hook::flag;
use signal_hook::iterator::{Handle as SignalHandle, Signals};
use tokio::sync::watch as tokio_watch;

use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};

static IGNORED_SIGPIPE: OnceLock<Result<Arc<AtomicBool>, String>> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ShutdownSignalAction {
    RequestGracefulShutdown,
    ForceExit(i32),
}

pub(crate) struct ShutdownSignalGuard {
    handle: SignalHandle,
    thread: Option<JoinHandle<()>>,
}

impl ShutdownSignalGuard {
    pub(crate) fn install(shutdown_tx: tokio_watch::Sender<bool>) -> Result<Self, CliError> {
        ignore_sigpipe()?;
        let mut signals = Signals::new([SIGTERM, SIGINT, SIGHUP]).map_err(|error| {
            CliErrorKind::workflow_io(format!("install daemon signal handlers: {error}"))
        })?;
        let handle = signals.handle();
        let force_exit_armed = Arc::new(AtomicBool::new(false));
        let thread = thread::Builder::new()
            .name("daemon-signals".to_string())
            .spawn(move || run_signal_loop(&mut signals, &shutdown_tx, &force_exit_armed))
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("spawn daemon signal thread: {error}"))
            })?;
        Ok(Self {
            handle,
            thread: Some(thread),
        })
    }
}

impl Drop for ShutdownSignalGuard {
    fn drop(&mut self) {
        self.handle.close();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn ignore_sigpipe() -> Result<(), CliError> {
    match IGNORED_SIGPIPE.get_or_init(|| {
        let ignored = Arc::new(AtomicBool::new(false));
        flag::register(SIGPIPE, Arc::clone(&ignored))
            .map(|_| ignored)
            .map_err(|error| format!("ignore SIGPIPE during daemon shutdown: {error}"))
    }) {
        Ok(_) => Ok(()),
        Err(message) => Err(CliError::from(CliErrorKind::workflow_io(message.clone()))),
    }
}

fn run_signal_loop(
    signals: &mut Signals,
    shutdown_tx: &tokio_watch::Sender<bool>,
    force_exit_armed: &AtomicBool,
) {
    for signal in signals.forever() {
        handle_signal(signal, shutdown_tx, force_exit_armed);
    }
}

fn handle_signal(
    signal: i32,
    shutdown_tx: &tokio_watch::Sender<bool>,
    force_exit_armed: &AtomicBool,
) {
    match shutdown_signal_action(force_exit_armed, signal) {
        ShutdownSignalAction::RequestGracefulShutdown => {
            request_graceful_shutdown(signal, shutdown_tx);
        }
        ShutdownSignalAction::ForceExit(exit_code) => force_exit(signal, exit_code),
    }
}

fn shutdown_signal_action(force_exit_armed: &AtomicBool, signal: i32) -> ShutdownSignalAction {
    if force_exit_armed.swap(true, Ordering::SeqCst) {
        ShutdownSignalAction::ForceExit(exit_code_for_signal(signal))
    } else {
        ShutdownSignalAction::RequestGracefulShutdown
    }
}

fn exit_code_for_signal(signal: i32) -> i32 {
    128_i32.saturating_add(signal)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing and cleanup branches in shutdown signal helper"
)]
fn request_graceful_shutdown(signal: i32, shutdown_tx: &tokio_watch::Sender<bool>) {
    tracing::info!(
        signal,
        "daemon received shutdown signal; requesting graceful shutdown"
    );
    if let Err(error) = notify_shutdown_request(shutdown_tx) {
        tracing::warn!(%error, signal, "signal daemon shutdown");
        force_exit(signal, exit_code_for_signal(signal));
    }
    state::append_event_best_effort(
        "info",
        &format!("daemon shutdown requested by signal {signal}"),
    );
}

fn notify_shutdown_request(
    shutdown_tx: &tokio_watch::Sender<bool>,
) -> Result<(), tokio_watch::error::SendError<bool>> {
    shutdown_tx.send(true)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing and cleanup branches in forced-exit helper"
)]
fn force_exit(signal: i32, exit_code: i32) -> ! {
    tracing::warn!(
        signal,
        exit_code,
        "daemon received repeated shutdown signal; forcing exit"
    );
    if let Err(error) = state::clear_manifest_for_pid(process_id()) {
        tracing::warn!(%error, signal, "clear daemon manifest during forced shutdown");
    }
    exit(exit_code);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_signal_requests_graceful_shutdown() {
        let force_exit_armed = AtomicBool::new(false);

        assert_eq!(
            shutdown_signal_action(&force_exit_armed, SIGINT),
            ShutdownSignalAction::RequestGracefulShutdown
        );
        assert!(force_exit_armed.load(Ordering::SeqCst));
    }

    #[test]
    fn second_signal_forces_exit_with_signal_code() {
        let force_exit_armed = AtomicBool::new(false);
        let _ = shutdown_signal_action(&force_exit_armed, SIGINT);

        assert_eq!(
            shutdown_signal_action(&force_exit_armed, SIGTERM),
            ShutdownSignalAction::ForceExit(exit_code_for_signal(SIGTERM))
        );
    }

    #[test]
    fn notify_shutdown_request_sets_watch_channel_true() {
        let (shutdown_tx, shutdown_rx) = tokio_watch::channel(false);

        notify_shutdown_request(&shutdown_tx).expect("signal shutdown");

        assert!(*shutdown_rx.borrow());
    }
}
