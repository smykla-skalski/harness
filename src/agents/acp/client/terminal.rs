//! Terminal management for ACP client.
//!
//! Unix-specific process group handling uses `killpg(2)`.

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::v1::{
    CreateTerminalRequest, CreateTerminalResponse, KillTerminalRequest, KillTerminalResponse,
    ReleaseTerminalRequest, ReleaseTerminalResponse, TerminalId, TerminalOutputRequest,
    TerminalOutputResponse, WaitForTerminalExitRequest, WaitForTerminalExitResponse,
};
use portable_pty::{Child as PtyChild, CommandBuilder, MasterPty, PtySize, native_pty_system};

use super::{ClientCallCancel, ClientError, ClientResult};
use crate::agents::acp::supervision::MAX_TERMINAL_WALL_CLOCK;
use crate::agents::policy::DeniedBinaries;

mod lifecycle;
mod output;
mod policy;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod wait_event;
mod wait_signal;

use lifecycle::{
    close_reader, refresh_exit_status, spawn_exit_monitor, terminate_process_group,
    terminate_terminal, wait_for_terminal_exit_state,
};
use output::spawn_output_reader;
use policy::denied_binary_name;
#[cfg(test)]
use wait_event::WaitEventCounter;
pub(super) use wait_signal::{TerminalLifecycleWait, TerminalWaitSignal};

pub(super) struct TerminalOutputState {
    pub(super) output: Vec<u8>,
    pub(super) truncated: bool,
    pub(super) output_limit: u64,
}

pub(super) type SharedTerminalChild = Arc<Mutex<Box<dyn PtyChild + Send + Sync>>>;
pub(super) type SharedTerminalState = Arc<Mutex<TerminalState>>;

enum TerminalSlot {
    Reserved,
    Ready(SharedTerminalState),
}

/// State for a spawned terminal process.
pub struct TerminalState {
    /// The child process.
    pub child: SharedTerminalChild,
    /// Master PTY handle kept alive for the terminal lifetime.
    pub master: Option<Box<dyn MasterPty + Send>>,
    /// Background reader for the PTY output stream.
    pub reader_thread: Option<JoinHandle<()>>,
    /// Background lifecycle monitor for exit detection.
    pub lifecycle_thread: Option<JoinHandle<()>>,
    /// Process group id (pgid) for signal delivery.
    pub pgid: Option<i32>,
    /// Accumulated output buffer and truncation state.
    output: Arc<Mutex<TerminalOutputState>>,
    /// Wakeup signal for exit/output lifecycle changes.
    pub signal: Arc<TerminalWaitSignal>,
    /// Wall-clock start for enforcing the per-terminal lifetime cap.
    spawned_at: Instant,
    /// Maximum wall-clock lifetime for this terminal.
    wall_clock_limit: Duration,
}

/// Terminal manager holding active terminals.
pub struct TerminalManager {
    /// Active terminals keyed by id.
    terminals: Mutex<HashMap<String, TerminalSlot>>,
    /// Counter for generating terminal ids.
    counter: Mutex<u64>,
    /// Maximum terminals per session.
    cap: usize,
    /// Maximum wall-clock per terminal.
    wall_clock_limit: Duration,
    /// Test-only count of waits that have registered before blocking.
    #[cfg(test)]
    wait_started: WaitEventCounter,
    /// Test-only count of waits that have finished, recorded before the handler
    /// releases so tests can prove a wait was still outstanding when a probe on
    /// another terminal returned.
    #[cfg(test)]
    wait_finished: WaitEventCounter,
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
            cap,
            wall_clock_limit,
            #[cfg(test)]
            wait_started: WaitEventCounter::new(),
            #[cfg(test)]
            wait_finished: WaitEventCounter::new(),
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
        Self::validate_create_request(request, denied_binaries)?;

        let terminal_id = self.reserve_slot()?;

        let state = match self.spawn_terminal(request, &request.command) {
            Ok(terminal) => terminal,
            Err(error) => {
                self.discard_slot(&terminal_id);
                return Err(error);
            }
        };

        {
            let mut terminals = self.terminals.lock().unwrap();
            let Some(slot) = terminals.get_mut(&terminal_id) else {
                return Err(ClientError::terminal_denied(format!(
                    "reserved terminal slot for '{terminal_id}' disappeared"
                )));
            };
            *slot = TerminalSlot::Ready(state);
        }

        Ok(CreateTerminalResponse::new(TerminalId::new(terminal_id)))
    }

    pub(super) fn validate_create_request(
        request: &CreateTerminalRequest,
        denied_binaries: &DeniedBinaries,
    ) -> ClientResult<()> {
        if let Some(name) = denied_binary_name(&request.command, &request.args, denied_binaries) {
            return Err(ClientError::terminal_denied(format!(
                "denied binary '{name}': use harness commands instead"
            )));
        }

        Ok(())
    }

    fn spawn_terminal(
        &self,
        request: &CreateTerminalRequest,
        command: &str,
    ) -> ClientResult<SharedTerminalState> {
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

        let output = Arc::new(Mutex::new(TerminalOutputState {
            output: Vec::new(),
            truncated: false,
            output_limit: request.output_byte_limit.unwrap_or(1024 * 1024),
        }));
        let signal = Arc::new(TerminalWaitSignal::new());
        let child = Arc::new(Mutex::new(child));
        let state = Arc::new(Mutex::new(TerminalState {
            child: Arc::clone(&child),
            master: Some(pair.master),
            reader_thread: None,
            lifecycle_thread: None,
            pgid,
            output: Arc::clone(&output),
            signal: Arc::clone(&signal),
            spawned_at: Instant::now(),
            wall_clock_limit: self.wall_clock_limit,
        }));
        let reader_thread = spawn_output_reader(reader, Arc::clone(&output), Arc::clone(&signal));
        let lifecycle_thread = spawn_exit_monitor(child, signal);
        {
            let mut state_guard = state.lock().unwrap();
            state_guard.reader_thread = Some(reader_thread);
            state_guard.lifecycle_thread = Some(lifecycle_thread);
        }

        Ok(state)
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

        if let Some(exit_status) = state.signal.exit_status() {
            response = response.exit_status(exit_status);
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
        cancel: &ClientCallCancel,
    ) -> ClientResult<WaitForTerminalExitResponse> {
        let terminal_id = request.terminal_id.0.as_ref();

        let state = self.terminal_state(terminal_id, &request.terminal_id)?;
        #[cfg(test)]
        self.wait_started.record();
        let exit_status = wait_for_terminal_exit_state(&state, cancel);
        #[cfg(test)]
        self.wait_finished.record();

        Ok(WaitForTerminalExitResponse::new(exit_status?))
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

        if state.signal.exit_status().is_some() {
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
            match terminals.remove(terminal_id) {
                Some(TerminalSlot::Ready(state)) => state,
                _ => return Err(ClientError::terminal_not_found(&request.terminal_id)),
            }
        };

        let mut state = state.lock().unwrap();
        let _ = refresh_exit_status(&mut state);
        if state.signal.exit_status().is_none() {
            terminate_terminal(&mut state);
        } else {
            terminate_process_group(&state);
        }

        close_reader(&mut state);

        Ok(ReleaseTerminalResponse::new())
    }

    fn reserve_slot(&self) -> ClientResult<String> {
        let mut terminals = self.terminals.lock().unwrap();
        if terminals.len() >= self.cap {
            return Err(ClientError::terminal_denied(format!(
                "terminal cap ({}) reached",
                self.cap
            )));
        }
        loop {
            let terminal_id = {
                let mut counter = self.counter.lock().unwrap();
                *counter += 1;
                format!("terminal-{}", *counter)
            };
            if let Entry::Vacant(entry) = terminals.entry(terminal_id.clone()) {
                entry.insert(TerminalSlot::Reserved);
                return Ok(terminal_id);
            }
        }
    }

    fn discard_slot(&self, terminal_id: &str) {
        let mut terminals = self.terminals.lock().unwrap();
        terminals.remove(terminal_id);
    }

    fn terminal_state(
        &self,
        terminal_id: &str,
        schema_id: &TerminalId,
    ) -> ClientResult<SharedTerminalState> {
        let terminals = self.terminals.lock().unwrap();
        terminals
            .get(terminal_id)
            .and_then(|slot| match slot {
                TerminalSlot::Reserved => None,
                TerminalSlot::Ready(state) => Some(Arc::clone(state)),
            })
            .ok_or_else(|| ClientError::terminal_not_found(schema_id))
    }

    #[cfg(test)]
    pub(super) fn wait_started_count(&self) -> u64 {
        self.wait_started.count()
    }

    #[cfg(test)]
    pub(super) fn await_wait_started(&self, target: u64, timeout: Duration) -> bool {
        self.wait_started.wait_until(target, timeout)
    }

    #[cfg(test)]
    pub(super) fn wait_finished_count(&self) -> u64 {
        self.wait_finished.count()
    }
}
