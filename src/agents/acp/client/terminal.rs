//! Terminal management for ACP client.
//!
//! Unix-specific process group handling uses `setsid(2)` and `killpg(2)`.
#![allow(unsafe_code)]

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::{
    CreateTerminalRequest, CreateTerminalResponse, KillTerminalRequest, KillTerminalResponse,
    ReleaseTerminalRequest, ReleaseTerminalResponse, TerminalExitStatus, TerminalId,
    TerminalOutputRequest, TerminalOutputResponse, WaitForTerminalExitRequest,
    WaitForTerminalExitResponse,
};
use portable_pty::{Child as PtyChild, CommandBuilder, MasterPty, PtySize, native_pty_system};

use super::{ClientError, ClientResult};
use crate::agents::acp::supervision::MAX_TERMINAL_WALL_CLOCK;
use crate::agents::policy::DeniedBinaries;

mod lifecycle;
mod output;
mod policy;
#[cfg(test)]
mod tests;

use lifecycle::{
    close_reader, refresh_exit_status, terminate_process_group, terminate_terminal,
    wait_for_terminal_exit_state,
};
use output::spawn_output_reader;
use policy::denied_binary_name;

pub(super) struct TerminalOutputState {
    pub(super) output: Vec<u8>,
    pub(super) truncated: bool,
    pub(super) output_limit: u64,
}

type SharedTerminalState = Arc<Mutex<TerminalState>>;

/// State for a spawned terminal process.
pub struct TerminalState {
    /// The child process.
    pub child: Box<dyn PtyChild + Send + Sync>,
    /// Master PTY handle kept alive for the terminal lifetime.
    pub master: Option<Box<dyn MasterPty + Send>>,
    /// Background reader for the PTY output stream.
    pub reader_thread: Option<JoinHandle<()>>,
    /// Process group id (pgid) for signal delivery.
    pub pgid: Option<i32>,
    /// Accumulated output buffer and truncation state.
    output: Arc<Mutex<TerminalOutputState>>,
    /// Wall-clock start for enforcing the per-terminal lifetime cap.
    spawned_at: Instant,
    /// Maximum wall-clock lifetime for this terminal.
    wall_clock_limit: Duration,
    /// Exit status if the process has exited.
    pub exit_status: Option<TerminalExitStatus>,
}

/// Terminal manager holding active terminals.
pub struct TerminalManager {
    /// Active terminals keyed by id.
    terminals: Mutex<HashMap<String, SharedTerminalState>>,
    /// Counter for generating terminal ids.
    counter: Mutex<u64>,
    /// Active terminal slots, including terminals being spawned.
    active_slots: Mutex<usize>,
    /// Maximum terminals per session.
    cap: usize,
    /// Maximum wall-clock per terminal.
    wall_clock_limit: Duration,
}

impl TerminalManager {
    #[must_use]
    pub fn new(cap: usize) -> Self {
        Self::new_with_limits(cap, MAX_TERMINAL_WALL_CLOCK)
    }

    #[must_use]
    pub(super) fn new_with_limits(cap: usize, wall_clock_limit: Duration) -> Self {
        Self {
            terminals: Mutex::new(HashMap::new()),
            counter: Mutex::new(0),
            active_slots: Mutex::new(0),
            cap,
            wall_clock_limit,
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

        if let Some(name) = denied_binary_name(command, &request.args, denied_binaries) {
            return Err(ClientError::terminal_denied(format!(
                "denied binary '{name}': use harness commands instead"
            )));
        }

        self.reserve_slot()?;

        let (terminal_id, state) = match self.spawn_terminal(request, command) {
            Ok(terminal) => terminal,
            Err(error) => {
                self.release_slot();
                return Err(error);
            }
        };

        {
            let mut terminals = self.terminals.lock().unwrap();
            terminals.insert(terminal_id.clone(), Arc::new(Mutex::new(state)));
        }

        Ok(CreateTerminalResponse::new(TerminalId::new(terminal_id)))
    }

    fn spawn_terminal(
        &self,
        request: &CreateTerminalRequest,
        command: &str,
    ) -> ClientResult<(String, TerminalState)> {
        let mut cmd = CommandBuilder::new(command);
        cmd.args(&request.args);

        for env_var in &request.env {
            cmd.env(&env_var.name, &env_var.value);
        }

        if let Some(ref cwd) = request.cwd {
            cmd.cwd(cwd);
        }

        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| ClientError::terminal_denied(format!("failed to open pty: {e}")))?;
        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| ClientError::terminal_denied(format!("failed to read pty: {e}")))?;
        // `portable_pty` performs the Unix `setsid(2)` handoff when spawning
        // through the slave side, so the process id is also the process group.
        let child = pair.slave.spawn_command(cmd).map_err(|e| {
            ClientError::terminal_denied(format!("failed to spawn '{command}': {e}"))
        })?;

        #[cfg(unix)]
        let pgid = child.process_id().and_then(|pid| i32::try_from(pid).ok());
        #[cfg(not(unix))]
        let pgid = None;

        let terminal_id = {
            let mut counter = self.counter.lock().unwrap();
            *counter += 1;
            format!("terminal-{}", *counter)
        };

        let output = Arc::new(Mutex::new(TerminalOutputState {
            output: Vec::new(),
            truncated: false,
            output_limit: request.output_byte_limit.unwrap_or(1024 * 1024),
        }));
        let reader_thread = spawn_output_reader(reader, Arc::clone(&output));

        let state = TerminalState {
            child,
            master: Some(pair.master),
            reader_thread: Some(reader_thread),
            pgid,
            output,
            spawned_at: Instant::now(),
            wall_clock_limit: self.wall_clock_limit,
            exit_status: None,
        };

        Ok((terminal_id, state))
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

        let state = self.terminal_state(terminal_id, &request.terminal_id)?;
        let mut state = state.lock().unwrap();

        refresh_exit_status(&mut state)?;

        let output = state.output.lock().unwrap();
        let mut response = TerminalOutputResponse::new(
            String::from_utf8_lossy(&output.output).into_owned(),
            output.truncated,
        );

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
            let state = self.terminal_state(terminal_id, &request.terminal_id)?;
            let mut state = state.lock().unwrap();
            wait_for_terminal_exit_state(&mut state)?
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

        let state = self.terminal_state(terminal_id, &request.terminal_id)?;
        let mut state = state.lock().unwrap();

        if state.exit_status.is_some() {
            return Ok(KillTerminalResponse::new());
        }

        terminate_terminal(&mut state);

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
        self.release_slot();

        let mut state = state.lock().unwrap();
        let _ = refresh_exit_status(&mut state);
        if state.exit_status.is_none() {
            terminate_terminal(&mut state);
        } else {
            terminate_process_group(&state);
        }

        close_reader(&mut state);

        Ok(ReleaseTerminalResponse::new())
    }

    fn reserve_slot(&self) -> ClientResult<()> {
        let mut slots = self.active_slots.lock().unwrap();
        if *slots >= self.cap {
            return Err(ClientError::terminal_denied(format!(
                "terminal cap ({}) reached",
                self.cap
            )));
        }
        *slots += 1;
        Ok(())
    }

    fn release_slot(&self) {
        let mut slots = self.active_slots.lock().unwrap();
        *slots = slots.saturating_sub(1);
    }

    fn terminal_state(
        &self,
        terminal_id: &str,
        schema_id: &TerminalId,
    ) -> ClientResult<SharedTerminalState> {
        let terminals = self.terminals.lock().unwrap();
        terminals
            .get(terminal_id)
            .cloned()
            .ok_or_else(|| ClientError::terminal_not_found(schema_id))
    }
}
