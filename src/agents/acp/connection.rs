//! ACP connection management with fold-flush receive loop.
//!
//! Owns the SDK `ClientSideConnection`, runs a receive loop on a dedicated tokio
//! task. Implements fold + flush batching: reads until SDK reader returns Pending
//! or accumulated 32 updates / 64 KiB / 5 ms, then sends one batch per channel.

use std::env;
use std::io;
use std::path::PathBuf;
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use agent_client_protocol::schema::SessionNotification;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::ChildStdout;
use tokio::sync::mpsc;
use tokio::task::{JoinError, JoinHandle};
use tokio::time::sleep;
use tracing::{debug, info, warn};

use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};

use super::events::materialise_batch;
use super::program::resolve_program;
use super::ring::{RingConfig, SessionRing};
use super::supervision::{AcpSessionSupervisor, WatchdogEventEmitter, WatchdogState};

/// Batch of materialised events ready for downstream consumption.
///
/// `raw_count == 0` is the synthetic-batch marker: the batch did not come from
/// agent stdout but from a daemon-side producer (e.g. `SupervisorEventSink`
/// emitting watchdog transitions). Downstream consumers that meter agent
/// throughput should filter on `raw_count > 0`; consumers that surface
/// supervisor signal must NOT filter synthetic batches out.
#[derive(Debug)]
pub struct EventBatch {
    /// Harness ACP logical session id.
    pub acp_id: String,
    /// Harness session id that owns this batch.
    pub session_id: String,
    /// The conversation events in this batch.
    pub events: Vec<ConversationEvent>,
    /// Number of raw updates that produced these events. Zero on synthetic
    /// batches emitted by daemon-side producers.
    pub raw_count: usize,
}

/// Configuration for the connection receive loop.
#[derive(Debug, Clone)]
pub struct ConnectionConfig {
    /// Ring buffer flush thresholds.
    pub ring: RingConfig,
    /// Channel buffer size for event batches.
    pub channel_buffer: usize,
}

impl Default for ConnectionConfig {
    fn default() -> Self {
        Self {
            ring: RingConfig::default(),
            channel_buffer: 64,
        }
    }
}

/// Handle to a running ACP connection.
///
/// The receive loop runs on a spawned task; this handle provides the event
/// channel and cancellation.
#[derive(Debug)]
pub struct AcpConnectionHandle {
    /// Receiver for event batches.
    pub events: mpsc::Receiver<EventBatch>,
    /// Join handle for the receive task.
    task: JoinHandle<()>,
}

impl AcpConnectionHandle {
    /// Split the handle into its event receiver and receive-loop task.
    #[must_use]
    pub fn into_parts(self) -> (mpsc::Receiver<EventBatch>, JoinHandle<()>) {
        (self.events, self.task)
    }

    /// Wait for the receive loop to complete.
    ///
    /// # Errors
    ///
    /// Returns a [`JoinError`] if the receive-loop task panics or is cancelled.
    pub async fn join(self) -> Result<(), JoinError> {
        self.task.await
    }

    /// Abort the receive loop.
    pub fn abort(&self) {
        self.task.abort();
    }
}

/// Sink that materialises supervisor watchdog transitions into the same
/// conversation event stream used by the ACP receive loop.
///
/// Each emit produces a single-event `EventBatch` with `raw_count: 0` so
/// downstream consumers can distinguish synthetic supervisor events from
/// agent stdout.
///
/// **Channel scope:** the `mpsc::Sender` passed to `new` is the per-session
/// channel created by `spawn_receive_loop`. There is one sink per session,
/// one channel per session, so a saturating burst on session A's channel
/// cannot starve session B's supervisor signal. A dropped Fired/Done batch
/// here means *this* session's UI lost the terminal transition; the operator
/// must read the daemon log to detect that case (the `warn!` line names the
/// session_id explicitly).
///
/// **Sequence-space contract:** `SupervisorEventSink::sequence` is a
/// SEPARATE counter from the receive loop's transcript sequence. Both
/// counters start at 0 and increment independently. Downstream consumers
/// MUST key on `(entry_kind, sequence)` and never on `sequence` alone.
/// `entries.rs::conversation_entry` already encodes this: the synthesized
/// `entry_id` is `format!("{runtime}-{agent_id}-{entry_kind}-{sequence}")`,
/// where `entry_kind` includes `agent_watchdog_state` for supervisor events
/// and disjoint kind strings for transcript events, so collisions are
/// impossible by construction.
pub struct SupervisorEventSink {
    tx: mpsc::Sender<EventBatch>,
    agent_name: String,
    session_id: String,
    /// Synthetic-event sequence space, disjoint from the receive loop's
    /// transcript sequence. See type-level doc for the contract.
    sequence: AtomicU64,
}

impl SupervisorEventSink {
    /// Build a sink bound to the supplied event channel and identity.
    #[must_use]
    pub fn new(tx: mpsc::Sender<EventBatch>, agent_name: String, session_id: String) -> Self {
        Self {
            tx,
            agent_name,
            session_id,
            sequence: AtomicU64::new(0),
        }
    }

    /// Emit a synthetic `PermissionAsked` event into the per-session channel.
    ///
    /// Producer site: `HarnessAcpClient::handle_request_permission` calls this
    /// on every permission gate, regardless of mode. The variant is never
    /// terminal (the watchdog stays alive while the user is deciding).
    pub fn emit_permission_asked(&self, tool: String, scope: String, request_id: Option<String>) {
        self.emit(
            ConversationEventKind::PermissionAsked {
                tool,
                scope,
                request_id,
            },
            false,
        );
    }

    /// Emit a synthetic `ContextInjected` event into the per-session channel.
    ///
    /// Producer site: `daemon::agent_acp::manager::session_access::record_wake_accept`
    /// calls this once the wake-prompt ack lands, so the timeline shows that
    /// the dispatched context was received. Never terminal.
    pub fn emit_context_injected(&self, actor: String, summary: Option<String>) {
        self.emit(
            ConversationEventKind::ContextInjected { actor, summary },
            false,
        );
    }

    fn emit(&self, kind: ConversationEventKind, terminal: bool) {
        let sequence = self.sequence.fetch_add(1, Ordering::SeqCst);
        let event = ConversationEvent {
            timestamp: Some(chrono::Utc::now().to_rfc3339()),
            sequence,
            kind,
            agent: self.agent_name.clone(),
            session_id: self.session_id.clone(),
        };
        let batch = EventBatch {
            acp_id: self.session_id.clone(),
            session_id: self.session_id.clone(),
            events: vec![event],
            raw_count: 0,
        };
        if let Err(err) = self.tx.try_send(batch) {
            // Terminal transitions (Fired/Done) must surface in production logs
            // because the operator's fault-isolation story depends on them.
            // Non-terminal transitions stay at debug to avoid noise during
            // routine activity bursts that fill the channel.
            if terminal {
                warn!(error = %err, session_id = %self.session_id, "supervisor event sink dropped TERMINAL watchdog batch (receiver full or closed)");
            } else {
                debug!(error = %err, "supervisor event sink dropped batch (receiver full or closed)");
            }
        }
    }
}

impl WatchdogEventEmitter for SupervisorEventSink {
    fn emit_state(&self, from: WatchdogState, to: WatchdogState, reason: Option<&str>) {
        let terminal = matches!(to, WatchdogState::Fired | WatchdogState::Done);
        self.emit(
            ConversationEventKind::WatchdogState {
                from: from.as_str().to_string(),
                to: to.as_str().to_string(),
                reason: reason.map(str::to_string),
            },
            terminal,
        );
    }

    fn emit_permission_asked(&self, tool: String, scope: String, request_id: Option<String>) {
        SupervisorEventSink::emit_permission_asked(self, tool, scope, request_id);
    }

    fn emit_context_injected(&self, actor: String, summary: Option<String>) {
        SupervisorEventSink::emit_context_injected(self, actor, summary);
    }
}

/// Spawn the receive loop for an ACP child process.
///
/// Reads NDJSON from the child's stdout, batches notifications using the ring
/// buffer, and sends materialised events to the returned channel.
///
/// # Panics
///
/// Panics when the child was not spawned with piped stdout or when the stdout
/// handle cannot be converted into Tokio's async process handle.
#[must_use]
pub fn spawn_receive_loop(
    child: &mut Child,
    agent_name: String,
    session_id: String,
    supervisor: Arc<AcpSessionSupervisor>,
    config: ConnectionConfig,
) -> AcpConnectionHandle {
    let stdout = child
        .stdout
        .take()
        .expect("child stdout not captured; spawn with Stdio::piped()");

    let async_stdout = ChildStdout::from_std(stdout).expect("failed to convert stdout to async");

    let (tx, rx) = mpsc::channel(config.channel_buffer);

    let supervisor_sink = Arc::new(SupervisorEventSink::new(
        tx.clone(),
        agent_name.clone(),
        session_id.clone(),
    ));
    supervisor.attach_event_emitter(supervisor_sink);

    let task = tokio::spawn(receive_loop(
        async_stdout,
        tx,
        agent_name,
        session_id,
        supervisor,
        config.ring,
    ));

    AcpConnectionHandle { events: rx, task }
}

/// The main receive loop.
///
/// Reads lines from stdout, parses as `SessionNotification`, accumulates in the
/// ring, and flushes batches to the channel.
#[expect(
    clippy::cognitive_complexity,
    reason = "tokio::select! and tracing macro expansion inflate this two-branch receive loop"
)]
async fn receive_loop(
    stdout: ChildStdout,
    tx: mpsc::Sender<EventBatch>,
    agent_name: String,
    session_id: String,
    supervisor: Arc<AcpSessionSupervisor>,
    ring_config: RingConfig,
) {
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let mut ring = SessionRing::new(ring_config);
    let mut sequence: u64 = 0;

    loop {
        line.clear();

        let flush_timeout = ring
            .elapsed()
            .and_then(|e| ring.config().max_duration.checked_sub(e))
            .unwrap_or(ring.config().max_duration);

        tokio::select! {
            biased;

            result = reader.read_line(&mut line) => {
                if !handle_read_result(
                    result,
                    &line,
                    &supervisor,
                    &mut ring,
                    &tx,
                    &agent_name,
                    &session_id,
                    &mut sequence,
                ).await {
                    break;
                }
            }

            () = sleep(flush_timeout), if !ring.is_empty() => {
                flush_ring(&mut ring, &tx, &agent_name, &session_id, &mut sequence).await;
            }
        }
    }

    if !ring.is_empty() {
        flush_ring(&mut ring, &tx, &agent_name, &session_id, &mut sequence).await;
    }

    info!(total_events = sequence, "ACP receive loop finished");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
#[expect(
    clippy::too_many_arguments,
    reason = "keeps the receive-loop branch explicit without bundling short-lived borrows"
)]
async fn handle_read_result(
    result: io::Result<usize>,
    line: &str,
    supervisor: &AcpSessionSupervisor,
    ring: &mut SessionRing,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) -> bool {
    match result {
        Ok(0) => {
            debug!("ACP stdout closed");
            false
        }
        Ok(_) => {
            supervisor.record_event();
            handle_notification_line(line.trim(), ring, tx, agent_name, session_id, sequence).await;
            true
        }
        Err(error) => {
            warn!(%error, "error reading from ACP stdout");
            false
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn handle_notification_line(
    trimmed: &str,
    ring: &mut SessionRing,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) {
    if trimmed.is_empty() {
        return;
    }

    match serde_json::from_str::<SessionNotification>(trimmed) {
        Ok(notification) => {
            if ring.push(notification) {
                flush_ring(ring, tx, agent_name, session_id, sequence).await;
            }
        }
        Err(error) => {
            debug!(line = %trimmed, %error, "failed to parse notification");
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn flush_ring(
    ring: &mut SessionRing,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) {
    if let Some(batch) = next_event_batch(ring, agent_name, session_id, sequence)
        && tx.send(batch).await.is_err()
    {
        debug!("event receiver dropped; stopping flush");
    }
}

fn next_event_batch(
    ring: &mut SessionRing,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) -> Option<EventBatch> {
    let raw_count = ring.len();
    if raw_count == 0 {
        return None;
    }
    let (events, next_seq) = materialise_batch(ring.updates(), agent_name, session_id, *sequence);
    *sequence = next_seq;
    ring.clear();
    Some(EventBatch {
        acp_id: session_id.to_string(),
        session_id: session_id.to_string(),
        events,
        raw_count,
    })
}

/// Parse a single NDJSON line into a `SessionNotification`.
///
/// Exposed for benchmarking.
///
/// # Errors
///
/// Returns [`serde_json::Error`] if the line is not a valid ACP notification.
pub fn parse_notification(line: &str) -> serde_json::Result<SessionNotification> {
    serde_json::from_str(line)
}

/// Spawn configuration for ACP child processes.
#[derive(Debug, Clone)]
pub struct SpawnConfig {
    /// Command to run.
    pub command: String,
    /// Arguments.
    pub args: Vec<String>,
    /// Environment variables to pass through.
    pub env_passthrough: Vec<String>,
    /// Working directory.
    pub working_dir: PathBuf,
}

impl SpawnConfig {
    #[must_use]
    pub fn resolved_command_for_identity(&self) -> String {
        resolve_program(&self.command)
            .unwrap_or_else(|| self.command.clone().into())
            .display()
            .to_string()
    }

    #[must_use]
    pub fn effective_env_for_identity(&self) -> Vec<(String, String)> {
        let mut values = env::vars().collect::<Vec<_>>();
        values.sort_by(|left, right| left.0.cmp(&right.0));
        values
    }

    /// Spawn the child process with stdio piped.
    ///
    /// On Unix, sets up a new process group via `setsid(2)` in the pre-exec hook.
    ///
    /// # Errors
    ///
    /// Returns an error if the process fails to spawn.
    #[cfg(unix)]
    #[expect(
        unsafe_code,
        reason = "pre_exec runs between fork and exec; unsafe is irreducible"
    )]
    pub fn spawn(&self) -> io::Result<Child> {
        use nix::unistd::setsid;
        use std::os::unix::process::CommandExt;
        use std::process::Command;

        let program = resolve_program(&self.command).unwrap_or_else(|| self.command.clone().into());
        let mut cmd = Command::new(program);
        cmd.args(&self.args)
            .current_dir(&self.working_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        for var in &self.env_passthrough {
            if let Ok(val) = env::var(var) {
                cmd.env(var, val);
            }
        }

        // SAFETY: pre_exec closure runs between fork and exec; setsid is async-signal-safe.
        unsafe {
            cmd.pre_exec(|| {
                setsid().map_err(io::Error::from)?;
                Ok(())
            });
        }

        cmd.spawn()
    }

    /// Spawn the child process with stdio piped (non-Unix).
    #[cfg(not(unix))]
    ///
    /// # Errors
    ///
    /// Returns an error if the process fails to spawn.
    pub fn spawn(&self) -> io::Result<Child> {
        use std::process::Command;

        let program = resolve_program(&self.command).unwrap_or_else(|| self.command.clone().into());
        let mut cmd = Command::new(program);
        cmd.args(&self.args)
            .current_dir(&self.working_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        for var in &self.env_passthrough {
            if let Ok(val) = env::var(var) {
                cmd.env(var, val);
            }
        }

        cmd.spawn()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::schema::{
        ContentBlock, ContentChunk, SessionId, SessionUpdate, TextContent,
    };

    #[test]
    fn parse_notification_valid() {
        let update = SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
            TextContent::new("hello"),
        )));
        let notif = SessionNotification::new(SessionId::new("test"), update);
        let json = serde_json::to_string(&notif).expect("serialize");

        parse_notification(&json).expect("failed to parse valid notification json");
    }

    #[test]
    fn parse_notification_invalid() {
        let json = r#"{"not":"valid"}"#;
        let result = parse_notification(json);
        assert!(result.is_err());
    }

    #[test]
    fn spawn_config_builds_command() {
        let config = SpawnConfig {
            command: "echo".to_string(),
            args: vec!["hello".to_string()],
            env_passthrough: vec![],
            working_dir: std::env::current_dir().unwrap(),
        };

        let mut child = config.spawn().expect("spawn echo");
        let _ = child.wait();
    }

    #[tokio::test]
    async fn event_batch_structure() {
        let batch = EventBatch {
            acp_id: "acp-1".to_string(),
            session_id: "sess-1".to_string(),
            events: vec![],
            raw_count: 5,
        };
        assert_eq!(batch.acp_id, "acp-1");
        assert_eq!(batch.session_id, "sess-1");
        assert_eq!(batch.raw_count, 5);
        assert!(batch.events.is_empty());
    }
}
