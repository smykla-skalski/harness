use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{JoinHandle, sleep, spawn};
use std::time::{Duration, Instant};

use portable_pty::{Child, ExitStatus, MasterPty, native_pty_system};
use tokio::sync::broadcast;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::input::AgentTuiInput;
use super::input_request::AgentTuiInputSequence;
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

pub(crate) struct AgentTuiAttachState {
    pub(crate) initial_bytes: Vec<u8>,
    pub(crate) broadcast_rx: broadcast::Receiver<Vec<u8>>,
}

enum QueuedAgentTuiInput {
    Immediate {
        input: AgentTuiInput,
        completion: SyncSender<Result<(), CliError>>,
    },
    Sequence {
        sequence: AgentTuiInputSequence,
        completion: SyncSender<Result<(), CliError>>,
    },
}

enum QueuedAgentTuiInputPoll {
    Input(QueuedAgentTuiInput),
    Timeout,
    Disconnected,
}

#[derive(Clone)]
pub(crate) struct AgentTuiInputWorker {
    sender: Sender<QueuedAgentTuiInput>,
    stop_flag: Arc<AtomicBool>,
    process: Arc<AgentTuiProcess>,
}

impl AgentTuiInputWorker {
    pub(crate) fn spawn(process: Arc<AgentTuiProcess>, stop_flag: Arc<AtomicBool>) -> Self {
        let (sender, receiver) = mpsc::channel();
        let worker = Self {
            sender,
            stop_flag: Arc::clone(&stop_flag),
            process: Arc::clone(&process),
        };
        spawn(move || {
            Self::run(&receiver, &process, &stop_flag);
        });
        worker
    }

    /// Queue one immediate input and wait until it has been replayed.
    ///
    /// # Errors
    /// Returns a session-not-active or transport error when the process has
    /// already stopped, the queue is unavailable, or the replay fails.
    pub(crate) fn send_input(&self, input: &AgentTuiInput) -> Result<(), CliError> {
        self.ensure_accepting_input()?;
        let (completion_tx, completion_rx) = mpsc::sync_channel(1);
        self.sender
            .send(QueuedAgentTuiInput::Immediate {
                input: input.clone(),
                completion: completion_tx,
            })
            .map_err(|_| {
                CliError::from(CliErrorKind::session_not_active(
                    "terminal agent input queue is no longer available",
                ))
            })?;
        completion_rx.recv().map_err(|_| {
            CliError::from(CliErrorKind::session_not_active(
                "terminal agent input queue stopped before replay completed",
            ))
        })?
    }

    /// Queue one timed sequence and wait until it finishes replaying.
    ///
    /// # Errors
    /// Returns a session-not-active or transport error when the process has
    /// already stopped, the queue is unavailable, or replay fails.
    pub(crate) fn enqueue_sequence(
        &self,
        sequence: &AgentTuiInputSequence,
    ) -> Result<(), CliError> {
        self.ensure_accepting_input()?;
        let (completion_tx, completion_rx) = mpsc::sync_channel(1);
        self.sender
            .send(QueuedAgentTuiInput::Sequence {
                sequence: sequence.clone(),
                completion: completion_tx,
            })
            .map_err(|_| {
                CliError::from(CliErrorKind::session_not_active(
                    "terminal agent input queue is no longer available",
                ))
            })?;
        completion_rx.recv().map_err(|_| {
            CliError::from(CliErrorKind::session_not_active(
                "terminal agent input queue stopped before replay completed",
            ))
        })?
    }

    fn ensure_accepting_input(&self) -> Result<(), CliError> {
        if self.stop_flag.load(Ordering::Relaxed) || self.process.try_wait()?.is_some() {
            return Err(
                CliErrorKind::session_not_active("terminal agent is no longer active").into(),
            );
        }
        Ok(())
    }

    fn run(
        receiver: &mpsc::Receiver<QueuedAgentTuiInput>,
        process: &Arc<AgentTuiProcess>,
        stop_flag: &Arc<AtomicBool>,
    ) {
        loop {
            if Self::transport_stopped(process, stop_flag).unwrap_or(true) {
                return;
            }
            match Self::poll_next_input(receiver) {
                QueuedAgentTuiInputPoll::Input(queued_input) => {
                    Self::handle_queued_input(process, stop_flag, queued_input);
                }
                QueuedAgentTuiInputPoll::Timeout => {}
                QueuedAgentTuiInputPoll::Disconnected => return,
            }
        }
    }

    fn poll_next_input(receiver: &mpsc::Receiver<QueuedAgentTuiInput>) -> QueuedAgentTuiInputPoll {
        match receiver.recv_timeout(Duration::from_millis(20)) {
            Ok(queued_input) => QueuedAgentTuiInputPoll::Input(queued_input),
            Err(RecvTimeoutError::Timeout) => QueuedAgentTuiInputPoll::Timeout,
            Err(RecvTimeoutError::Disconnected) => QueuedAgentTuiInputPoll::Disconnected,
        }
    }

    fn handle_queued_input(
        process: &AgentTuiProcess,
        stop_flag: &AtomicBool,
        queued_input: QueuedAgentTuiInput,
    ) {
        match queued_input {
            QueuedAgentTuiInput::Immediate { input, completion } => {
                let _ = completion.send(Self::replay_input(process, stop_flag, &input));
            }
            QueuedAgentTuiInput::Sequence {
                sequence,
                completion,
            } => {
                let _ = completion.send(Self::replay_sequence(process, stop_flag, &sequence));
            }
        }
    }

    fn replay_sequence(
        process: &AgentTuiProcess,
        stop_flag: &AtomicBool,
        sequence: &AgentTuiInputSequence,
    ) -> Result<(), CliError> {
        for step in &sequence.steps {
            Self::sleep_before_step(process, stop_flag, step.delay_before_ms)?;
            Self::replay_input(process, stop_flag, &step.input)?;
        }
        Ok(())
    }

    fn sleep_before_step(
        process: &AgentTuiProcess,
        stop_flag: &AtomicBool,
        delay_before_ms: u64,
    ) -> Result<(), CliError> {
        let delay = Duration::from_millis(delay_before_ms);
        if delay.is_zero() {
            return Self::ensure_transport_active(process, stop_flag);
        }
        let deadline = Instant::now() + delay;
        while Instant::now() < deadline {
            Self::ensure_transport_active(process, stop_flag)?;
            let remaining = deadline.saturating_duration_since(Instant::now());
            sleep(remaining.min(Duration::from_millis(10)));
        }
        Self::ensure_transport_active(process, stop_flag)
    }

    fn replay_input(
        process: &AgentTuiProcess,
        stop_flag: &AtomicBool,
        input: &AgentTuiInput,
    ) -> Result<(), CliError> {
        Self::ensure_transport_active(process, stop_flag)?;
        process.send_input(input)
    }

    fn ensure_transport_active(
        process: &AgentTuiProcess,
        stop_flag: &AtomicBool,
    ) -> Result<(), CliError> {
        if Self::transport_stopped(process, stop_flag)? {
            return Err(
                CliErrorKind::session_not_active("terminal agent is no longer active").into(),
            );
        }
        Ok(())
    }

    fn transport_stopped(
        process: &AgentTuiProcess,
        stop_flag: &AtomicBool,
    ) -> Result<bool, CliError> {
        if stop_flag.load(Ordering::Relaxed) {
            return Ok(true);
        }
        Ok(process.try_wait()?.is_some())
    }
}

/// Live process handle for a terminal agent running inside a PTY.
pub struct AgentTuiProcess {
    master: Shared<Box<dyn MasterPty + Send>>,
    child: Shared<Box<dyn Child + Send + Sync>>,
    writer: Shared<Box<dyn Write + Send>>,
    transcript: Shared<Vec<u8>>,
    persisted_transcript_len: Shared<usize>,
    screen: Shared<TerminalScreenParser>,
    pub(crate) broadcast_rx: broadcast::Receiver<Vec<u8>>,
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
        let pair = pty_system.openpty(spec.size.into()).map_err(|error| {
            CliErrorKind::workflow_io(format!("open terminal agent PTY: {error}"))
        })?;
        let cmd = command_builder(spec);
        let child = pair.slave.spawn_command(cmd).map_err(|error| {
            CliErrorKind::workflow_io(format!("spawn terminal agent process: {error}"))
        })?;
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().map_err(|error| {
            CliErrorKind::workflow_io(format!("clone terminal agent PTY reader: {error}"))
        })?;
        let writer = pair.master.take_writer().map_err(|error| {
            CliErrorKind::workflow_io(format!("take terminal agent PTY writer: {error}"))
        })?;

        let (broadcast_tx, broadcast_rx) = broadcast::channel(1024);
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
            broadcast_tx,
        );

        Ok(Self {
            master: Arc::new(Mutex::new(pair.master)),
            child: Arc::new(Mutex::new(child)),
            writer: Arc::new(Mutex::new(writer)),
            transcript,
            persisted_transcript_len,
            screen,
            broadcast_rx,
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
        let mut writer = lock(&self.writer, "terminal agent writer")?;
        writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("write terminal agent input: {error}")).into()
            })
    }

    /// Resize the PTY and the parsed screen model.
    ///
    /// # Errors
    /// Returns a workflow parse or I/O error when resize fails.
    pub fn resize(&self, size: AgentTuiSize) -> Result<(), CliError> {
        let size = size.validate()?;
        lock(&self.master, "terminal agent PTY master")?
            .resize(size.into())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("resize terminal agent PTY: {error}"))
            })?;
        lock(&self.screen, "terminal agent screen parser")?.resize(size);
        Ok(())
    }

    /// Return the latest parsed terminal screen.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn screen(&self) -> Result<TerminalScreenSnapshot, CliError> {
        Ok(lock(&self.screen, "terminal agent screen parser")?.snapshot())
    }

    /// Return a copy of the raw terminal transcript captured so far.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned.
    pub fn transcript(&self) -> Result<Vec<u8>, CliError> {
        Ok(lock(&self.transcript, "terminal agent transcript")?.clone())
    }

    pub(crate) fn attach_state(&self) -> Result<AgentTuiAttachState, CliError> {
        let broadcast_rx = self.broadcast_rx.resubscribe();
        let initial_bytes = lock(&self.screen, "terminal agent screen parser")?.state_formatted();
        Ok(AgentTuiAttachState {
            initial_bytes,
            broadcast_rx,
        })
    }

    /// Persist newly captured transcript bytes without rewriting the full file.
    ///
    /// # Errors
    /// Returns a workflow I/O error when internal state is poisoned or the file write fails.
    pub fn persist_transcript(&self, path: &Path) -> Result<(), CliError> {
        let transcript = lock(&self.transcript, "terminal agent transcript")?;
        let mut persisted_len = lock(
            &self.persisted_transcript_len,
            "terminal agent persisted transcript length",
        )?;
        persist_transcript(path, transcript.as_slice(), &mut persisted_len)
    }

    /// Poll the child process for exit status without blocking.
    ///
    /// # Errors
    /// Returns a workflow I/O error when process polling fails.
    pub fn try_wait(&self) -> Result<Option<ExitStatus>, CliError> {
        lock(&self.child, "terminal agent child")?
            .try_wait()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("poll terminal agent process: {error}")).into()
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
        lock(&self.child, "terminal agent child")?
            .kill()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("kill terminal agent process: {error}")).into()
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
