//! Terminal management for ACP client.
//!
//! Unix-specific process group handling uses `setsid(2)` and `killpg(2)`.
#![allow(unsafe_code)]

use std::collections::HashMap;
use std::io::ErrorKind;
use std::io::Read as StdRead;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::{
    CreateTerminalRequest, CreateTerminalResponse, KillTerminalRequest, KillTerminalResponse,
    ReleaseTerminalRequest, ReleaseTerminalResponse, TerminalExitStatus, TerminalId,
    TerminalOutputRequest, TerminalOutputResponse, WaitForTerminalExitRequest,
    WaitForTerminalExitResponse,
};
use portable_pty::{
    Child as PtyChild, CommandBuilder, ExitStatus as PtyExitStatus, MasterPty, PtySize,
    native_pty_system,
};

use super::{ClientError, ClientResult};
use crate::agents::policy::DeniedBinaries;

#[cfg(test)]
mod tests;

struct TerminalOutputState {
    output: Vec<u8>,
    truncated: bool,
    output_limit: u64,
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
}

impl TerminalManager {
    #[must_use]
    pub fn new(cap: usize) -> Self {
        Self {
            terminals: Mutex::new(HashMap::new()),
            counter: Mutex::new(0),
            active_slots: Mutex::new(0),
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

            if state.exit_status.is_none() {
                let status = state.child.wait().map_err(|e| {
                    ClientError::terminal_denied(format!("failed to wait for terminal: {e}"))
                })?;

                state.exit_status = Some(terminal_exit_status(&status));
                wait_for_output_drain(&state.output, Duration::from_millis(50));
                close_reader(&mut state);
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

fn denied_binary_name(
    command: &str,
    args: &[String],
    denied_binaries: &DeniedBinaries,
) -> Option<String> {
    denied_binary_token(command, denied_binaries)
        .or_else(|| denied_shell_command(command, args, denied_binaries))
        .or_else(|| denied_env_command(command, args, denied_binaries))
}

fn denied_binary_token(token: &str, denied_binaries: &DeniedBinaries) -> Option<String> {
    let token = token.trim_matches(|c: char| matches!(c, '"' | '\'' | ';' | '(' | ')' | '&' | '|'));
    if denied_binaries.contains(token) {
        return Some(token.to_string());
    }
    let file_name = Path::new(token).file_name()?.to_str()?;
    denied_binaries
        .contains(file_name)
        .then(|| file_name.to_string())
}

fn denied_shell_command(
    command: &str,
    args: &[String],
    denied_binaries: &DeniedBinaries,
) -> Option<String> {
    let shell = Path::new(command).file_name()?.to_str()?;
    if !matches!(shell, "sh" | "bash" | "zsh") {
        return None;
    }
    let command_line = args
        .windows(2)
        .find_map(|window| (window[0] == "-c").then_some(window[1].as_str()))?;
    let first_command = command_line
        .split_whitespace()
        .find(|token| !matches!(*token, "exec" | "command"))?;
    denied_binary_token(first_command, denied_binaries)
}

fn denied_env_command(
    command: &str,
    args: &[String],
    denied_binaries: &DeniedBinaries,
) -> Option<String> {
    let command_name = Path::new(command).file_name()?.to_str()?;
    if command_name != "env" {
        return None;
    }
    let target = args
        .iter()
        .find(|arg| !arg.starts_with('-') && !arg.contains('='))?;
    denied_binary_token(target, denied_binaries)
}

fn spawn_output_reader(
    mut reader: Box<dyn StdRead + Send>,
    output: Arc<Mutex<TerminalOutputState>>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => append_with_limit(&output, &buf[..n]),
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
    })
}

fn refresh_exit_status(state: &mut TerminalState) -> ClientResult<()> {
    if state.exit_status.is_some() {
        return Ok(());
    }
    match state.child.try_wait() {
        Ok(Some(status)) => {
            state.exit_status = Some(terminal_exit_status(&status));
            wait_for_output_drain(&state.output, Duration::from_millis(50));
            close_reader(state);
        }
        Ok(None) => {}
        Err(error) => {
            return Err(ClientError::terminal_denied(format!(
                "failed to poll terminal: {error}"
            )));
        }
    }
    Ok(())
}

/// Append bytes to a buffer with a limit, truncating from the front if needed.
fn append_with_limit(output: &Mutex<TerminalOutputState>, data: &[u8]) {
    let mut output = output.lock().unwrap();
    output.output.extend_from_slice(data);
    let limit = usize::try_from(output.output_limit).unwrap_or(usize::MAX);
    if limit == 0 {
        output.output.clear();
        output.truncated = true;
        return;
    }
    if output.output.len() > limit {
        let start = output.output.len() - limit;
        output.output.drain(..start);
        output.truncated = true;
    }
}

fn wait_for_output_drain(output: &Mutex<TerminalOutputState>, timeout: Duration) {
    let start = Instant::now();
    let mut previous_len = output.lock().unwrap().output.len();
    while start.elapsed() < timeout {
        thread::sleep(Duration::from_millis(5));
        let len = output.lock().unwrap().output.len();
        if len > 0 && len == previous_len {
            return;
        }
        previous_len = len;
    }
}

fn terminal_exit_status(status: &PtyExitStatus) -> TerminalExitStatus {
    let exit_status = TerminalExitStatus::new().exit_code(Some(status.exit_code()));
    if let Some(signal) = status.signal() {
        exit_status.signal(signal.to_string())
    } else {
        exit_status
    }
}

fn terminate_terminal(state: &mut TerminalState) {
    if refresh_exit_status(state).is_ok() && state.exit_status.is_some() {
        close_reader(state);
        return;
    }

    #[cfg(unix)]
    if let Some(pgid) = state.pgid {
        unsafe {
            libc::killpg(pgid, libc::SIGTERM);
        }

        if !poll_terminal_exit(state, Duration::from_secs(3)) {
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

fn terminate_process_group(state: &TerminalState) {
    #[cfg(unix)]
    if let Some(pgid) = state.pgid {
        unsafe {
            libc::killpg(pgid, libc::SIGTERM);
        }
    }
}

fn poll_terminal_exit(state: &mut TerminalState, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        match state.child.try_wait() {
            Ok(Some(status)) => {
                state.exit_status = Some(terminal_exit_status(&status));
                return true;
            }
            Ok(None) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(50));
            }
            Ok(None) | Err(_) => return false,
        }
    }
}

fn close_reader(state: &mut TerminalState) {
    state.master.take();
    // Dropping the handle detaches the reader. Joining can hang if a terminal
    // descendant keeps the PTY slave open after the direct child exits.
    state.reader_thread.take();
}
