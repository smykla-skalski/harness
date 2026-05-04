use std::sync::Arc;
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::TerminalExitStatus;
use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;
use portable_pty::ExitStatus as PtyExitStatus;
use tracing::warn;

use super::output::wait_for_output_drain;
use super::{
    SharedTerminalChild, SharedTerminalState, TerminalLifecycleWait, TerminalState,
    TerminalWaitSignal,
};
use crate::agents::acp::client::{ClientError, ClientResult};

pub(super) fn spawn_exit_monitor(
    child: SharedTerminalChild,
    signal: Arc<TerminalWaitSignal>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        loop {
            if signal.exit_status().is_some() || signal.lifecycle_error().is_some() {
                return;
            }

            let wait_result = {
                let mut child = child.lock().unwrap();
                child.try_wait()
            };

            match wait_result {
                Ok(Some(status)) => {
                    signal.finish_exit(terminal_exit_status(&status));
                    return;
                }
                Ok(None) => {
                    let snapshot = signal.snapshot();
                    let _ = signal.wait_for_change(snapshot, Duration::from_millis(50));
                }
                Err(error) => {
                    signal.fail_poll(format!("failed to poll terminal: {error}"));
                    return;
                }
            }
        }
    })
}

pub(super) fn refresh_exit_status(state: &mut TerminalState) -> ClientResult<()> {
    if state.signal.exit_status().is_some() {
        return Ok(());
    }
    if let Some(error) = state.signal.lifecycle_error() {
        return Err(ClientError::terminal_denied(error));
    }
    if state.spawned_at.elapsed() >= state.wall_clock_limit {
        terminate_running_terminal(state);
        return Err(ClientError::terminal_denied(format!(
            "terminal exceeded wall-clock limit of {} seconds",
            state.wall_clock_limit.as_secs()
        )));
    }
    Ok(())
}

pub(super) fn wait_for_terminal_exit_state(
    state: &SharedTerminalState,
) -> ClientResult<TerminalExitStatus> {
    loop {
        let (signal, remaining) = {
            let mut state = state.lock().unwrap();
            refresh_exit_status(&mut state)?;
            if let Some(exit_status) = state.signal.exit_status() {
                return Ok(exit_status);
            }
            (
                Arc::clone(&state.signal),
                state
                    .wall_clock_limit
                    .saturating_sub(state.spawned_at.elapsed()),
            )
        };
        match signal.wait_for_exit_or_error(remaining) {
            TerminalLifecycleWait::Exit(exit_status) => return Ok(exit_status),
            TerminalLifecycleWait::LifecycleError(error) => {
                return Err(ClientError::terminal_denied(error));
            }
            TerminalLifecycleWait::TimedOut => {}
        }
    }
}

pub(super) fn terminate_terminal(state: &mut TerminalState) {
    if state.signal.exit_status().is_some() || wait_for_terminal_exit_signal(state, Duration::ZERO)
    {
        close_reader(state);
        return;
    }
    terminate_running_terminal(state);
}

#[cfg(unix)]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn send_signals_and_drain(pgid: i32, state: &mut TerminalState) {
    if let Err(e) = killpg(Pid::from_raw(pgid), Signal::SIGTERM) {
        warn!(pgid, error = %e, "SIGTERM to terminal process group failed");
    }
    if !wait_for_terminal_exit_signal(state, Duration::from_secs(3))
        && let Err(e) = killpg(Pid::from_raw(pgid), Signal::SIGKILL)
    {
        warn!(pgid, error = %e, "SIGKILL to terminal process group failed");
    }
    let _ = wait_for_terminal_exit_signal(state, Duration::from_millis(250));
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(super) fn terminate_process_group(state: &TerminalState) {
    #[cfg(unix)]
    if let Some(pgid) = state.pgid {
        if let Err(e) = killpg(Pid::from_raw(pgid), Signal::SIGTERM) {
            warn!(pgid, error = %e, "SIGTERM to terminal process group failed");
        }
        if !wait_for_reader_close(&state.signal, Duration::from_millis(250))
            && let Err(e) = killpg(Pid::from_raw(pgid), Signal::SIGKILL)
        {
            warn!(pgid, error = %e, "SIGKILL to terminal process group failed");
        }
        let _ = wait_for_reader_close(&state.signal, Duration::from_millis(250));
    }
}

fn wait_for_terminal_exit_signal(state: &TerminalState, timeout: Duration) -> bool {
    match state.signal.wait_for_exit_or_error(timeout) {
        TerminalLifecycleWait::Exit(_) => true,
        TerminalLifecycleWait::LifecycleError(_) | TerminalLifecycleWait::TimedOut => false,
    }
}

fn wait_for_reader_close(signal: &TerminalWaitSignal, timeout: Duration) -> bool {
    let start = Instant::now();
    let mut snapshot = signal.snapshot();
    while !snapshot.reader_closed && start.elapsed() < timeout {
        let remaining = timeout.saturating_sub(start.elapsed());
        let next = signal.wait_for_change(snapshot, remaining);
        if next.generation == snapshot.generation && next.reader_closed == snapshot.reader_closed {
            return next.reader_closed;
        }
        snapshot = next;
    }
    snapshot.reader_closed
}

fn kill_child(state: &TerminalState) {
    let _ = state.child.lock().unwrap().kill();
}

fn block_on_child_exit(state: &TerminalState) {
    if state.signal.exit_status().is_some() {
        return;
    }
    let wait_result = {
        let mut child = state.child.lock().unwrap();
        child.wait()
    };
    match wait_result {
        Ok(status) => state.signal.finish_exit(terminal_exit_status(&status)),
        Err(error) => state
            .signal
            .fail_poll(format!("failed to wait terminal: {error}")),
    }
}

fn finish_terminal(state: &mut TerminalState) {
    wait_for_output_drain(&state.signal, Duration::from_millis(50));
    close_reader(state);
}

fn terminate_running_terminal(state: &mut TerminalState) {
    #[cfg(unix)]
    if let Some(pgid) = state.pgid {
        send_signals_and_drain(pgid, state);
    } else {
        kill_child(state);
    }

    #[cfg(not(unix))]
    {
        kill_child(state);
    }

    if state.signal.exit_status().is_none() {
        block_on_child_exit(state);
    }

    finish_terminal(state);
}

fn terminal_exit_status(status: &PtyExitStatus) -> TerminalExitStatus {
    let exit_status = TerminalExitStatus::new().exit_code(Some(status.exit_code()));
    if let Some(signal) = status.signal() {
        exit_status.signal(signal.to_string())
    } else {
        exit_status
    }
}

pub(super) fn close_reader(state: &mut TerminalState) {
    state.master.take();
    // Dropping the handle detaches the reader. Joining can hang if a terminal
    // descendant keeps the PTY slave open after the direct child exits.
    state.reader_thread.take();
    state.lifecycle_thread.take();
}
