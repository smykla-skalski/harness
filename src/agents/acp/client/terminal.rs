//! Terminal management for ACP client.
//!
//! Unix-specific process group handling uses `setsid(2)` and `killpg(2)`.
#![allow(unsafe_code)]

use std::collections::HashMap;
use std::io::Read as StdRead;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use agent_client_protocol::schema::{
    CreateTerminalRequest, CreateTerminalResponse, KillTerminalRequest, KillTerminalResponse,
    ReleaseTerminalRequest, ReleaseTerminalResponse, TerminalExitStatus, TerminalId,
    TerminalOutputRequest, TerminalOutputResponse, WaitForTerminalExitRequest,
    WaitForTerminalExitResponse,
};

use super::{ClientError, ClientResult};
use crate::agents::policy::DeniedBinaries;

/// State for a spawned terminal process.
#[derive(Debug)]
pub struct TerminalState {
    /// The child process.
    pub child: Child,
    /// Process group id (pgid) for signal delivery.
    pub pgid: Option<i32>,
    /// Accumulated output buffer.
    pub output: Vec<u8>,
    /// Maximum output bytes to retain.
    pub output_limit: u64,
    /// Whether the output was truncated.
    pub truncated: bool,
    /// Exit status if the process has exited.
    pub exit_status: Option<TerminalExitStatus>,
}

/// Terminal manager holding active terminals.
pub struct TerminalManager {
    /// Active terminals keyed by id.
    terminals: Mutex<HashMap<String, TerminalState>>,
    /// Counter for generating terminal ids.
    counter: Mutex<u64>,
    /// Maximum terminals per session.
    cap: usize,
}

impl TerminalManager {
    #[must_use]
    pub fn new(cap: usize) -> Self {
        Self {
            terminals: Mutex::new(HashMap::new()),
            counter: Mutex::new(0),
            cap,
        }
    }

    /// Handle `terminal/create`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_DENIED` if the command is a denied binary or the cap
    /// is reached, or if the process fails to spawn.
    pub fn handle_create(
        &self,
        request: &CreateTerminalRequest,
        denied_binaries: &DeniedBinaries,
    ) -> ClientResult<CreateTerminalResponse> {
        let command = &request.command;

        if denied_binaries.contains(command) {
            return Err(ClientError::terminal_denied(format!(
                "denied binary '{command}': use harness commands instead"
            )));
        }

        {
            let terminals = self.terminals.lock().unwrap();
            if terminals.len() >= self.cap {
                return Err(ClientError::terminal_denied(format!(
                    "terminal cap ({}) reached",
                    self.cap
                )));
            }
        }

        let mut cmd = Command::new(command);
        cmd.args(&request.args);
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());

        for env_var in &request.env {
            cmd.env(&env_var.name, &env_var.value);
        }

        if let Some(ref cwd) = request.cwd {
            cmd.current_dir(cwd);
        }

        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            unsafe {
                cmd.pre_exec(|| {
                    libc::setsid();
                    Ok(())
                });
            }
        }

        let child = cmd.spawn().map_err(|e| {
            ClientError::terminal_denied(format!("failed to spawn '{command}': {e}"))
        })?;

        #[cfg(unix)]
        let pgid = Some(child.id().cast_signed());
        #[cfg(not(unix))]
        let pgid = None;

        let terminal_id = {
            let mut counter = self.counter.lock().unwrap();
            *counter += 1;
            format!("terminal-{}", *counter)
        };

        let state = TerminalState {
            child,
            pgid,
            output: Vec::new(),
            output_limit: request.output_byte_limit.unwrap_or(1024 * 1024),
            truncated: false,
            exit_status: None,
        };

        {
            let mut terminals = self.terminals.lock().unwrap();
            terminals.insert(terminal_id.clone(), state);
        }

        Ok(CreateTerminalResponse::new(TerminalId::new(terminal_id)))
    }

    /// Handle `terminal/output`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown.
    pub fn handle_output(
        &self,
        request: &TerminalOutputRequest,
    ) -> ClientResult<TerminalOutputResponse> {
        let terminal_id = request.terminal_id.0.as_ref();

        let mut terminals = self.terminals.lock().unwrap();
        let state = terminals
            .get_mut(terminal_id)
            .ok_or_else(|| ClientError::terminal_not_found(&request.terminal_id))?;

        collect_output(state);

        let output = String::from_utf8_lossy(&state.output).into_owned();
        let mut response = TerminalOutputResponse::new(output, state.truncated);

        if let Some(ref exit_status) = state.exit_status {
            response = response.exit_status(exit_status.clone());
        }

        Ok(response)
    }

    /// Handle `terminal/wait_for_exit`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown, or
    /// `TERMINAL_DENIED` if the wait fails.
    pub fn handle_wait_for_exit(
        &self,
        request: &WaitForTerminalExitRequest,
    ) -> ClientResult<WaitForTerminalExitResponse> {
        let terminal_id = request.terminal_id.0.as_ref();

        let exit_status = {
            let mut terminals = self.terminals.lock().unwrap();
            let state = terminals
                .get_mut(terminal_id)
                .ok_or_else(|| ClientError::terminal_not_found(&request.terminal_id))?;

            if state.exit_status.is_none() {
                let status = state.child.wait().map_err(|e| {
                    ClientError::terminal_denied(format!("failed to wait for terminal: {e}"))
                })?;

                collect_output(state);

                let exit_status =
                    TerminalExitStatus::new().exit_code(status.code().map(i32::cast_unsigned));

                #[cfg(unix)]
                let exit_status = {
                    use std::os::unix::process::ExitStatusExt;
                    if let Some(signal) = status.signal() {
                        exit_status.signal(signal_name(signal))
                    } else {
                        exit_status
                    }
                };

                state.exit_status = Some(exit_status);
            }

            state.exit_status.clone().unwrap()
        };

        Ok(WaitForTerminalExitResponse::new(exit_status))
    }

    /// Handle `terminal/kill`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown.
    pub fn handle_kill(&self, request: &KillTerminalRequest) -> ClientResult<KillTerminalResponse> {
        let terminal_id = request.terminal_id.0.as_ref();

        let mut terminals = self.terminals.lock().unwrap();
        let state = terminals
            .get_mut(terminal_id)
            .ok_or_else(|| ClientError::terminal_not_found(&request.terminal_id))?;

        if state.exit_status.is_some() {
            return Ok(KillTerminalResponse::new());
        }

        #[cfg(unix)]
        if let Some(pgid) = state.pgid {
            unsafe {
                libc::killpg(pgid, libc::SIGTERM);
            }

            // Grace period for SIGTERM before escalating to SIGKILL. 3 seconds
            // is a common default (systemd TimeoutStopSec, Docker stop). If
            // processes routinely need longer, this should become configurable.
            // TODO: Consider releasing the mutex during the sleep to avoid
            // blocking concurrent terminal operations.
            thread::sleep(Duration::from_secs(3));

            match state.child.try_wait() {
                Ok(Some(_)) => {}
                _ => unsafe {
                    libc::killpg(pgid, libc::SIGKILL);
                },
            }
        }

        #[cfg(not(unix))]
        {
            let _ = state.child.kill();
        }

        Ok(KillTerminalResponse::new())
    }

    /// Handle `terminal/release`.
    ///
    /// # Errors
    ///
    /// Returns `TERMINAL_NOT_FOUND` if the terminal id is unknown.
    pub fn handle_release(
        &self,
        request: &ReleaseTerminalRequest,
    ) -> ClientResult<ReleaseTerminalResponse> {
        let terminal_id = request.terminal_id.0.as_ref();

        let state = {
            let mut terminals = self.terminals.lock().unwrap();
            terminals
                .remove(terminal_id)
                .ok_or_else(|| ClientError::terminal_not_found(&request.terminal_id))?
        };

        if state.exit_status.is_none() {
            #[cfg(unix)]
            if let Some(pgid) = state.pgid {
                unsafe {
                    libc::killpg(pgid, libc::SIGKILL);
                }
            }
        }

        Ok(ReleaseTerminalResponse::new())
    }
}

/// Collect output from a terminal's stdout/stderr.
fn collect_output(state: &mut TerminalState) {
    if let Some(ref mut stdout) = state.child.stdout {
        let mut buf = [0u8; 4096];
        while let Ok(n) = stdout.read(&mut buf) {
            if n == 0 {
                break;
            }
            append_with_limit(
                &mut state.output,
                &buf[..n],
                state.output_limit,
                &mut state.truncated,
            );
        }
    }
    if let Some(ref mut stderr) = state.child.stderr {
        let mut buf = [0u8; 4096];
        while let Ok(n) = stderr.read(&mut buf) {
            if n == 0 {
                break;
            }
            append_with_limit(
                &mut state.output,
                &buf[..n],
                state.output_limit,
                &mut state.truncated,
            );
        }
    }
}

/// Append bytes to a buffer with a limit, truncating from the front if needed.
#[expect(clippy::cast_possible_truncation, reason = "limit from u64 user input")]
fn append_with_limit(buf: &mut Vec<u8>, data: &[u8], limit: u64, truncated: &mut bool) {
    buf.extend_from_slice(data);
    let limit = limit as usize;
    if buf.len() > limit {
        let excess = buf.len() - limit;
        buf.drain(..excess);
        *truncated = true;
    }
}

/// Convert a signal number to a name.
#[cfg(unix)]
fn signal_name(signal: i32) -> String {
    match signal {
        libc::SIGTERM => "SIGTERM".to_string(),
        libc::SIGKILL => "SIGKILL".to_string(),
        libc::SIGINT => "SIGINT".to_string(),
        libc::SIGHUP => "SIGHUP".to_string(),
        libc::SIGQUIT => "SIGQUIT".to_string(),
        _ => format!("SIG{signal}"),
    }
}
