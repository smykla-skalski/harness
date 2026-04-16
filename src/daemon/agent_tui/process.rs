use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread::{JoinHandle, sleep};
use std::time::{Duration, Instant};

use portable_pty::{Child, ExitStatus, MasterPty, native_pty_system};
use tokio::sync::broadcast;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::input::AgentTuiInput;
use super::model::{
    AgentTuiLaunchProfile, AgentTuiSize, AgentTuiSnapshot, AgentTuiSpawnSpec, AgentTuiStatus,
};
use super::readiness::{ReadinessSignal, new_readiness_signal, spawn_reader_thread};
use super::screen::{TerminalScreenParser, TerminalScreenSnapshot};
use super::spawn::command_builder;
use super::support::{Shared, lock, persist_transcript};

pub(crate) struct AgentTuiSnapshotContext<'a> {
    pub(crate) session_id: &'a str,
    pub(crate) agent_id: &'a str,
    pub(crate) tui_id: &'a str,
    pub(crate) profile: &'a AgentTuiLaunchProfile,
    pub(crate) project_dir: &'a Path,
    pub(crate) transcript_path: &'a Path,
}

pub(crate) fn snapshot_from_process(
    context: &AgentTuiSnapshotContext<'_>,
    process: &AgentTuiProcess,
    status: AgentTuiStatus,
) -> Result<AgentTuiSnapshot, CliError> {
    let screen = process.screen()?;
    process.persist_transcript(context.transcript_path)?;
    let now = utc_now();
    Ok(AgentTuiSnapshot {
        tui_id: context.tui_id.to_string(),
        session_id: context.session_id.to_string(),
        agent_id: context.agent_id.to_string(),
        runtime: context.profile.runtime.clone(),
        status,
        argv: context.profile.argv.clone(),
        project_dir: context.project_dir.display().to_string(),
        size: screen.size(),
        screen,
        transcript_path: context.transcript_path.display().to_string(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: now.clone(),
        updated_at: now,
    })
}

/// Live process handle for an agent TUI running inside a PTY.
pub struct AgentTuiProcess {
    master: Shared<Box<dyn MasterPty + Send>>,
    child: Shared<Box<dyn Child + Send + Sync>>,
    writer: Shared<Box<dyn Write + Send>>,
    transcript: Shared<Vec<u8>>,
    persisted_transcript_len: Shared<usize>,
    screen: Shared<TerminalScreenParser>,
    #[allow(dead_code)]
    pub(crate) broadcast_tx: broadcast::Sender<Vec<u8>>,
    reader_thread: Option<JoinHandle<()>>,
    readiness: ReadinessSignal,
}

impl AgentTuiProcess {
    /// Spawn a child process into a PTY and start the output reader thread.
    ///
    /// # Errors
    /// Returns a workflow I/O error on PTY allocation, command spawn, or stream setup failure.
    pub fn spawn(spec: &AgentTuiSpawnSpec) -> Result<Self, CliError> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(spec.size.into())
            .map_err(|error| CliErrorKind::workflow_io(format!("open agent TUI PTY: {error}")))?;
        let cmd = command_builder(spec);
        let child = pair.slave.spawn_command(cmd).map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn agent TUI process: {error}"))
        })?;
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().map_err(|error| {
            CliErrorKind::workflow_io(format!("clone agent TUI PTY reader: {error}"))
        })?;
        let writer = pair.master.take_writer().map_err(|error| {
            CliErrorKind::workflow_io(format!("take agent TUI PTY writer: {error}"))
        })?;

        let (broadcast_tx, _) = broadcast::channel(1024);
        let transcript = Arc::new(Mutex::new(Vec::new()));
        let persisted_transcript_len = Arc::new(Mutex::new(0_usize));
        let screen = Arc::new(Mutex::new(TerminalScreenParser::new(spec.size)));
        let readiness = new_readiness_signal();
        let reader_thread = spawn_reader_thread(
            reader,
            Arc::clone(&transcript),
            Arc::clone(&screen),
            spec.readiness_pattern,
            spec.screen_text_fallback,
            Arc::clone(&readiness),
            broadcast_tx.clone(),
        );

        Ok(Self {
            master: Arc::new(Mutex::new(pair.master)),
            child: Arc::new(Mutex::new(child)),
            writer: Arc::new(Mutex::new(writer)),
            transcript,
            persisted_transcript_len,
            screen,
            broadcast_tx,
            reader_thread: Some(reader_thread),
            readiness,
        })
    }

    /// Send structured keyboard input to the PTY.
    ///
    /// # Errors
    /// Returns a workflow parse or I/O error when mapping or writing input fails.
    pub fn send_input(&self, input: &AgentTuiInput) -> Result<(), CliError> {
        self.write_bytes(&input.to_bytes()?)
    }

    /// Send raw bytes to the PTY.
    ///
    /// # Errors
    /// Returns a workflow I/O error when the PTY writer fails.
    pub fn write_bytes(&self, bytes: &[u8]) -> Result<(), CliError> {
        let mut writer = lock(&self.writer, "agent TUI writer")?;
        writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("write agent TUI input: {error}")).into()
            })
    }

    /// Resize the PTY and the parsed screen model.
    ///
    /// # Errors
    /// Returns a workflow parse or I/O error when resize fails.
    pub fn resize(&self, size: AgentTuiSize) -> Result<(), CliError> {
        let size = size.validate()?;
        lock(&self.master, "agent TUI PTY master")?
            .resize(size.into())
            .map_err(|error| CliErrorKind::workflow_io(format!("resize agent TUI PTY: {error}")))?;
        lock(&self.screen, "agent TUI screen parser")?.resize(size);
        Ok(())
    }

    /// Return the latest parsed terminal screen.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn screen(&self) -> Result<TerminalScreenSnapshot, CliError> {
        Ok(lock(&self.screen, "agent TUI screen parser")?.snapshot())
    }

    /// Return a copy of the raw terminal transcript captured so far.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn transcript(&self) -> Result<Vec<u8>, CliError> {
        Ok(lock(&self.transcript, "agent TUI transcript")?.clone())
    }

    /// Persist newly captured transcript bytes without rewriting the full file.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned or the file write fails.
    pub fn persist_transcript(&self, path: &Path) -> Result<(), CliError> {
        let transcript = lock(&self.transcript, "agent TUI transcript")?;
        let mut persisted_len = lock(
            &self.persisted_transcript_len,
            "agent TUI persisted transcript length",
        )?;
        persist_transcript(path, transcript.as_slice(), &mut persisted_len)
    }

    /// Poll the child process for exit status without blocking.
    ///
    /// # Errors
    /// Returns a workflow I/O error when process polling fails.
    pub fn try_wait(&self) -> Result<Option<ExitStatus>, CliError> {
        lock(&self.child, "agent TUI child")?
            .try_wait()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("poll agent TUI process: {error}")).into()
            })
    }

    /// Wait until the child exits or the timeout elapses.
    ///
    /// # Errors
    /// Returns a workflow I/O error when polling fails.
    pub fn wait_timeout(&self, timeout: Duration) -> Result<Option<ExitStatus>, CliError> {
        let started = Instant::now();
        loop {
            if let Some(status) = self.try_wait()? {
                return Ok(Some(status));
            }
            if started.elapsed() >= timeout {
                return Ok(None);
            }
            sleep(Duration::from_millis(20));
        }
    }

    /// Terminate the child process.
    ///
    /// # Errors
    /// Returns a workflow I/O error when process termination fails.
    pub fn kill(&self) -> Result<(), CliError> {
        lock(&self.child, "agent TUI child")?
            .kill()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("kill agent TUI process: {error}")).into()
            })
    }

    /// Block until the readiness pattern is detected or the timeout elapses.
    ///
    /// Returns `true` if the pattern was found, `false` on timeout or if the
    /// process exits before becoming ready. When no readiness pattern was
    /// configured at spawn time, returns `true` immediately.
    #[must_use]
    pub fn wait_ready(&self, timeout: Duration) -> bool {
        let (state, condvar) = &*self.readiness;
        let Ok(mut guard) = state.lock() else {
            return false;
        };
        let deadline = Instant::now() + timeout;
        while !guard.ready && !guard.closed {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            match condvar.wait_timeout(guard, remaining) {
                Ok((new_guard, result)) => {
                    guard = new_guard;
                    if result.timed_out() {
                        return guard.ready;
                    }
                }
                Err(_) => return false,
            }
        }
        guard.ready
    }

    pub(crate) fn readiness_signal(&self) -> ReadinessSignal {
        Arc::clone(&self.readiness)
    }
}

impl Drop for AgentTuiProcess {
    fn drop(&mut self) {
        if self
            .wait_timeout(Duration::from_millis(10))
            .ok()
            .flatten()
            .is_none()
            && let Ok(mut child) = self.child.lock()
        {
            let _ = child.kill();
        }
        if let Some(reader_thread) = self.reader_thread.take() {
            let _ = reader_thread.join();
        }
    }
}
