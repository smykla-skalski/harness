use std::fs;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;

/// A signal file sent to an agent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Signal {
    pub signal_id: String,
    pub version: u32,
    pub created_at: String,
    pub expires_at: String,
    pub source_agent: String,
    pub command: String,
    pub priority: SignalPriority,
    pub payload: SignalPayload,
    pub delivery: DeliveryConfig,
}

/// Signal priority level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalPriority {
    Low,
    Normal,
    High,
    Urgent,
}

/// Signal payload content.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalPayload {
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_hint: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub related_files: Vec<String>,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub metadata: Value,
}

/// Delivery configuration for retry semantics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeliveryConfig {
    pub max_retries: u32,
    #[serde(default)]
    pub retry_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

/// Acknowledgment written after a signal is processed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalAck {
    pub signal_id: String,
    pub acknowledged_at: String,
    pub result: AckResult,
    pub agent: String,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

/// Result of signal processing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AckResult {
    Accepted,
    Rejected,
    Deferred,
    Expired,
}

/// Compute the pending signals directory for an agent session.
#[must_use]
pub fn pending_dir(signal_dir: &Path) -> PathBuf {
    signal_dir.join("pending")
}

/// Compute the acknowledged signals directory for an agent session.
#[must_use]
pub fn acknowledged_dir(signal_dir: &Path) -> PathBuf {
    signal_dir.join("acknowledged")
}

/// Write a signal file atomically to the pending directory.
///
/// # Errors
/// Returns `CliError` on filesystem or serialization failures.
pub fn write_signal_file(signal_dir: &Path, signal: &Signal) -> Result<PathBuf, CliError> {
    let pending = pending_dir(signal_dir);
    fs::create_dir_all(&pending)
        .map_err(|error| CliErrorKind::workflow_io(format!("create signal dir: {error}")))?;
    let filename = format!("{}.json", signal.signal_id);
    let target = pending.join(&filename);
    let content = serde_json::to_string_pretty(signal)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("signal: {error}")))?;
    write_text(&target, &content)?;
    Ok(target)
}

/// Read all pending signal files from the directory.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn read_pending_signals(signal_dir: &Path) -> Result<Vec<Signal>, CliError> {
    read_json_files_from_dir::<Signal>(&pending_dir(signal_dir))
}

fn read_json_files_from_dir<T: DeserializeOwned>(dir: &Path) -> Result<Vec<T>, CliError> {
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let items = fs::read_dir(dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("read dir: {error}")))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .filter_map(|path| try_parse_json_file(&path))
        .collect();
    Ok(items)
}

fn try_parse_json_file<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let content = fs::read_to_string(path).ok()?;
    serde_json::from_str::<T>(&content).ok()
}

/// Acknowledge a signal: write ack file and move signal from pending to acknowledged.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn acknowledge_signal(signal_dir: &Path, ack: &SignalAck) -> Result<(), CliError> {
    let pending = pending_dir(signal_dir);
    let acked = acknowledged_dir(signal_dir);
    fs::create_dir_all(&acked)
        .map_err(|error| CliErrorKind::workflow_io(format!("create ack dir: {error}")))?;

    let signal_file = pending.join(format!("{}.json", ack.signal_id));
    let ack_file = acked.join(format!("{}.ack.json", ack.signal_id));

    let ack_json = serde_json::to_string_pretty(ack)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("ack: {error}")))?;
    write_text(&ack_file, &ack_json)?;

    // Atomic move: rename fails silently if another process already moved it
    let _ = fs::rename(&signal_file, acked.join(format!("{}.json", ack.signal_id)));

    Ok(())
}

/// Read all acknowledgment files from the directory.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn read_acknowledgments(signal_dir: &Path) -> Result<Vec<SignalAck>, CliError> {
    read_json_files_from_dir::<SignalAck>(&acknowledged_dir(signal_dir))
}

/// Read acknowledged signal payloads that have already been moved out of pending.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn read_acknowledged_signals(signal_dir: &Path) -> Result<Vec<Signal>, CliError> {
    let dir = acknowledged_dir(signal_dir);
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let items = fs::read_dir(dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("read dir: {error}")))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.extension().is_some_and(|ext| ext == "json")
                && !path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.ends_with(".ack.json"))
        })
        .filter_map(|path| try_parse_json_file(&path))
        .collect();
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn sample_signal() -> Signal {
        Signal {
            signal_id: "sig-test-001".into(),
            version: 1,
            created_at: "2026-03-28T12:00:00Z".into(),
            expires_at: "2026-03-28T12:05:00Z".into(),
            source_agent: "claude".into(),
            command: "inject_context".into(),
            priority: SignalPriority::Normal,
            payload: SignalPayload {
                message: "test signal".into(),
                action_hint: None,
                related_files: vec![],
                metadata: json!(null),
            },
            delivery: DeliveryConfig {
                max_retries: 3,
                retry_count: 0,
                idempotency_key: None,
            },
        }
    }

    #[test]
    fn signal_write_and_read_round_trip() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        let signal = sample_signal();
        write_signal_file(&signal_dir, &signal).unwrap();
        let signals = read_pending_signals(&signal_dir).unwrap();
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].signal_id, "sig-test-001");
    }

    #[test]
    fn acknowledge_moves_signal() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        let signal = sample_signal();
        write_signal_file(&signal_dir, &signal).unwrap();

        let ack = SignalAck {
            signal_id: "sig-test-001".into(),
            acknowledged_at: "2026-03-28T12:00:03Z".into(),
            result: AckResult::Accepted,
            agent: "codex".into(),
            session_id: "sess-1".into(),
            details: None,
        };
        acknowledge_signal(&signal_dir, &ack).unwrap();

        let pending = read_pending_signals(&signal_dir).unwrap();
        assert!(pending.is_empty());

        let acks = read_acknowledgments(&signal_dir).unwrap();
        assert_eq!(acks.len(), 1);
        assert_eq!(acks[0].result, AckResult::Accepted);
    }

    #[test]
    fn read_empty_dir_returns_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let signals = read_pending_signals(tmp.path()).unwrap();
        assert!(signals.is_empty());
        let acks = read_acknowledgments(tmp.path()).unwrap();
        assert!(acks.is_empty());
    }
}
