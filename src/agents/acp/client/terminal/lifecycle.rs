use std::thread;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::TerminalExitStatus;
use portable_pty::ExitStatus as PtyExitStatus;

use super::TerminalState;
use super::output::wait_for_output_drain;
use crate::agents::acp::client::{ClientError, ClientResult};

pub(super) fn refresh_exit_status(state: &mut TerminalState) -> ClientResult<()> {
    if state.exit_status.is_some() {
        return Ok(());
    }
    if state.spawned_at.elapsed() >= state.wall_clock_limit {
        terminate_running_terminal(state);
        return Err(ClientError::terminal_denied(format!(
            "terminal exceeded wall-clock limit of {} seconds",
            state.wall_clock_limit.as_secs()
        )));
    }
    poll_terminal_exit_status(state)
}

pub(super) fn wait_for_terminal_exit_state(
    state: &mut TerminalState,
) -> ClientResult<TerminalExitStatus> {
    loop {
        refresh_exit_status(state)?;
        if let Some(exit_status) = &state.exit_status {
            return Ok(exit_status.clone());
        }
        thread::sleep(Duration::from_millis(50));
    }
}

pub(super) fn terminate_terminal(state: &mut TerminalState) {
    if state.exit_status.is_some() || poll_terminal_exit(state, Duration::ZERO).unwrap_or(false) {
        close_reader(state);
        return;
    }
    terminate_running_terminal(state);
}

fn terminate_running_terminal(state: &mut TerminalState) {
    #[cfg(unix)]
    if let Some(pgid) = state.pgid {
        unsafe {
            libc::killpg(pgid, libc::SIGTERM);
        }

        if !poll_terminal_exit(state, Duration::from_secs(3)).unwrap_or(false) {
            unsafe {
                libc::killpg(pgid, libc::SIGKILL);
            }
        }
    } else {
        let _ = state.child.kill();
    }

    #[cfg(not(unix))]
    {
        let _ = state.child.kill();
    }

    if state.exit_status.is_none()
        && let Ok(status) = state.child.wait()
    {
        state.exit_status = Some(terminal_exit_status(&status));
    }

    close_reader(state);
}

pub(super) fn terminate_process_group(state: &TerminalState) {
    #[cfg(unix)]
    if let Some(pgid) = state.pgid {
        unsafe {
            libc::killpg(pgid, libc::SIGTERM);
        }
    }
}

fn poll_terminal_exit_status(state: &mut TerminalState) -> ClientResult<()> {
    match state.child.try_wait() {
        Ok(Some(status)) => finish_terminal(state, &status),
        Ok(None) => {}
        Err(error) => {
            return Err(ClientError::terminal_denied(format!(
                "failed to poll terminal: {error}"
            )));
        }
    }
    Ok(())
}

fn poll_terminal_exit(state: &mut TerminalState, timeout: Duration) -> ClientResult<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        match state.child.try_wait() {
            Ok(Some(status)) => {
                finish_terminal(state, &status);
                return Ok(true);
            }
            Ok(None) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(50));
            }
            Ok(None) => return Ok(false),
            Err(error) => {
                return Err(ClientError::terminal_denied(format!(
                    "failed to poll terminal: {error}"
                )));
            }
        }
    }
}

fn finish_terminal(state: &mut TerminalState, status: &PtyExitStatus) {
    state.exit_status = Some(terminal_exit_status(status));
    wait_for_output_drain(&state.output, Duration::from_millis(50));
    close_reader(state);
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
}
