//! ACP connection management with fold-flush receive loop.
//!
//! Owns the SDK `ClientSideConnection`, runs a receive loop on a dedicated tokio
//! task. Implements fold + flush batching: reads until SDK reader returns Pending
//! or accumulated 32 updates / 64 KiB / 5 ms, then sends one batch per channel.

use std::process::{Child, Stdio};
use std::sync::Arc;

use agent_client_protocol::schema::SessionNotification;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::ChildStdout;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::agents::runtime::event::ConversationEvent;

use super::events::materialise_batch;
use super::ring::{RingConfig, SessionRing};
use super::supervision::AcpSessionSupervisor;

/// Batch of materialised events ready for downstream consumption.
#[derive(Debug)]
pub struct EventBatch {
    /// The conversation events in this batch.
    pub events: Vec<ConversationEvent>,
    /// Number of raw updates that produced these events.
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
    task: tokio::task::JoinHandle<()>,
}

impl AcpConnectionHandle {
    /// Wait for the receive loop to complete.
    pub async fn join(self) -> Result<(), tokio::task::JoinError> {
        self.task.await
    }

    /// Abort the receive loop.
    pub fn abort(&self) {
        self.task.abort();
    }
}

/// Spawn the receive loop for an ACP child process.
///
/// Reads NDJSON from the child's stdout, batches notifications using the ring
/// buffer, and sends materialised events to the returned channel.
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

    let async_stdout =
        tokio::process::ChildStdout::from_std(stdout).expect("failed to convert stdout to async");

    let (tx, rx) = mpsc::channel(config.channel_buffer);

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
                match result {
                    Ok(0) => {
                        debug!("ACP stdout closed");
                        break;
                    }
                    Ok(_) => {
                        supervisor.record_event();

                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue;
                        }

                        match serde_json::from_str::<SessionNotification>(trimmed) {
                            Ok(notif) => {
                                let should_flush = ring.push(notif);
                                if should_flush {
                                    flush_ring(&mut ring, &tx, &agent_name, &session_id, &mut sequence).await;
                                }
                            }
                            Err(e) => {
                                debug!(line = %trimmed, error = %e, "failed to parse notification");
                            }
                        }
                    }
                    Err(e) => {
                        warn!(error = %e, "error reading from ACP stdout");
                        break;
                    }
                }
            }

            () = tokio::time::sleep(flush_timeout), if !ring.is_empty() => {
                flush_ring(&mut ring, &tx, &agent_name, &session_id, &mut sequence).await;
            }
        }
    }

    if !ring.is_empty() {
        flush_ring(&mut ring, &tx, &agent_name, &session_id, &mut sequence).await;
    }

    info!(total_events = sequence, "ACP receive loop finished");
}

async fn flush_ring(
    ring: &mut SessionRing,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) {
    let batch = ring.drain();
    let raw_count = batch.len();

    if raw_count == 0 {
        return;
    }

    let (events, next_seq) = materialise_batch(batch, agent_name, session_id, *sequence);
    *sequence = next_seq;

    let event_batch = EventBatch { events, raw_count };

    if tx.send(event_batch).await.is_err() {
        debug!("event receiver dropped; stopping flush");
    }
}

/// Parse a single NDJSON line into a `SessionNotification`.
///
/// Exposed for benchmarking.
pub fn parse_notification(line: &str) -> Result<SessionNotification, serde_json::Error> {
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
    pub working_dir: std::path::PathBuf,
}

impl SpawnConfig {
    /// Spawn the child process with stdio piped.
    ///
    /// On Unix, sets up a new process group via `setsid(2)` in the pre-exec hook.
    ///
    /// # Errors
    ///
    /// Returns an error if the process fails to spawn.
    #[cfg(unix)]
    #[allow(unsafe_code)]
    pub fn spawn(&self) -> std::io::Result<Child> {
        use std::os::unix::process::CommandExt;
        use std::process::Command;

        let mut cmd = Command::new(&self.command);
        cmd.args(&self.args)
            .current_dir(&self.working_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        for var in &self.env_passthrough {
            if let Ok(val) = std::env::var(var) {
                cmd.env(var, val);
            }
        }

        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }

        cmd.spawn()
    }

    /// Spawn the child process with stdio piped (non-Unix).
    #[cfg(not(unix))]
    pub fn spawn(&self) -> std::io::Result<Child> {
        use std::process::Command;

        let mut cmd = Command::new(&self.command);
        cmd.args(&self.args)
            .current_dir(&self.working_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        for var in &self.env_passthrough {
            if let Ok(val) = std::env::var(var) {
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

        let result = parse_notification(&json);
        assert!(result.is_ok(), "failed to parse: {json}");
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

        let child = config.spawn();
        assert!(child.is_ok());
        let mut child = child.unwrap();
        let _ = child.wait();
    }

    #[tokio::test]
    async fn event_batch_structure() {
        let batch = EventBatch {
            events: vec![],
            raw_count: 5,
        };
        assert_eq!(batch.raw_count, 5);
        assert!(batch.events.is_empty());
    }
}
