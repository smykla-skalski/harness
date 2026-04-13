use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::string::ToString;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{validate_safe_segment, write_text};

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

/// Whether a signal belongs to one orchestration session when it was loaded
/// from a possibly shared runtime-session signal directory.
#[must_use]
pub fn signal_matches_session(
    signal: &Signal,
    acknowledgment: Option<&SignalAck>,
    orchestration_session_id: &str,
    agent_id: &str,
    signal_session_id: &str,
) -> bool {
    if signal_session_id == orchestration_session_id {
        return true;
    }

    if let Some(idempotency_key) = signal.delivery.idempotency_key.as_deref() {
        let mut parts = idempotency_key.splitn(3, ':');
        return parts.next() == Some(orchestration_session_id)
            && parts.next() == Some(agent_id)
            && parts.next().is_some();
    }

    acknowledgment.is_some_and(|ack| ack.session_id == orchestration_session_id)
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

fn signal_json_name(signal_id: &str) -> Result<String, CliError> {
    validate_safe_segment(signal_id)?;
    Ok(format!("{signal_id}.json"))
}

fn signal_ack_name(signal_id: &str) -> Result<String, CliError> {
    validate_safe_segment(signal_id)?;
    Ok(format!("{signal_id}.ack.json"))
}

/// Write a signal file atomically to the pending directory.
///
/// # Errors
/// Returns `CliError` on filesystem or serialization failures.
pub fn write_signal_file(signal_dir: &Path, signal: &Signal) -> Result<PathBuf, CliError> {
    let pending = pending_dir(signal_dir);
    fs::create_dir_all(&pending)
        .map_err(|error| CliErrorKind::workflow_io(format!("create signal dir: {error}")))?;
    let filename = signal_json_name(&signal.signal_id)?;
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
    read_filtered_json_files(dir, |_| true)
}

fn read_filtered_json_files<T, F>(dir: &Path, include_path: F) -> Result<Vec<T>, CliError>
where
    T: DeserializeOwned,
    F: Fn(&Path) -> bool,
{
    let mut items = Vec::new();
    for path in read_json_entry_paths(dir)? {
        if include_path(&path)
            && let Some(item) = try_parse_json_file(&path)
        {
            items.push(item);
        }
    }
    Ok(items)
}

fn read_json_entry_paths(dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut paths = Vec::new();
    for entry in fs::read_dir(dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("read dir: {error}")))?
    {
        if let Some(path) = entry_path_or_warn(entry, dir)
            && is_json_path(&path)
        {
            paths.push(path);
        }
    }
    Ok(paths)
}

fn entry_path_or_warn(entry: Result<fs::DirEntry, io::Error>, dir: &Path) -> Option<PathBuf> {
    match entry {
        Ok(entry) => Some(entry.path()),
        Err(error) => {
            warn_signal_dir_entry_read_failure(dir, &error);
            None
        }
    }
}

fn is_json_path(path: &Path) -> bool {
    path.extension().is_some_and(|ext| ext == "json")
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_signal_dir_entry_read_failure(dir: &Path, error: &io::Error) {
    tracing::warn!(dir = %dir.display(), %error, "failed to read signal dir entry");
}

fn try_parse_json_file<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let content = read_json_file_contents(path)?;
    parse_json_file_contents(path, &content)
}

fn read_json_file_contents(path: &Path) -> Option<String> {
    match fs::read_to_string(path) {
        Ok(content) => Some(content),
        Err(error) => {
            warn_signal_json_read_failure(path, &error);
            None
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_signal_json_read_failure(path: &Path, error: &io::Error) {
    tracing::warn!(path = %path.display(), %error, "failed to read signal json file");
}

fn parse_json_file_contents<T: DeserializeOwned>(path: &Path, content: &str) -> Option<T> {
    match serde_json::from_str::<T>(content) {
        Ok(value) => Some(value),
        Err(error) => {
            quarantine_malformed_json_file(path, &error);
            None
        }
    }
}

struct AckPaths {
    acknowledged_dir: PathBuf,
    signal_file: PathBuf,
    ack_file: PathBuf,
    acknowledged_signal_file: PathBuf,
}

impl AckPaths {
    fn new(signal_dir: &Path, signal_id: &str) -> Result<Self, CliError> {
        let acknowledged_dir = acknowledged_dir(signal_dir);
        Ok(Self {
            acknowledged_dir: acknowledged_dir.clone(),
            signal_file: pending_dir(signal_dir).join(signal_json_name(signal_id)?),
            ack_file: acknowledged_dir.join(signal_ack_name(signal_id)?),
            acknowledged_signal_file: acknowledged_dir.join(signal_json_name(signal_id)?),
        })
    }
}

/// Acknowledge a signal: write ack file and move signal from pending to acknowledged.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn acknowledge_signal(signal_dir: &Path, ack: &SignalAck) -> Result<(), CliError> {
    let paths = AckPaths::new(signal_dir, &ack.signal_id)?;
    fs::create_dir_all(&paths.acknowledged_dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("create ack dir: {error}")))?;

    let ack_json = serde_json::to_string_pretty(ack)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("ack: {error}")))?;
    write_text(&paths.ack_file, &ack_json)?;
    move_acknowledged_signal(&paths.signal_file, &paths.acknowledged_signal_file)
}

fn move_acknowledged_signal(
    signal_file: &Path,
    acknowledged_signal_file: &Path,
) -> Result<(), CliError> {
    match fs::rename(signal_file, acknowledged_signal_file) {
        Ok(()) => Ok(()),
        Err(error) => {
            handle_acknowledge_rename_error(signal_file, acknowledged_signal_file, &error)
        }
    }
}

fn handle_acknowledge_rename_error(
    signal_file: &Path,
    acknowledged_signal_file: &Path,
    error: &io::Error,
) -> Result<(), CliError> {
    if acknowledge_rename_raced_with_prior_move(error, acknowledged_signal_file) {
        warn_acknowledge_rename_race(signal_file, acknowledged_signal_file);
        return Ok(());
    }

    Err(acknowledge_rename_failure(
        signal_file,
        acknowledged_signal_file,
        error,
    ))
}

fn acknowledge_rename_raced_with_prior_move(
    error: &io::Error,
    acknowledged_signal_file: &Path,
) -> bool {
    error.kind() == io::ErrorKind::NotFound && acknowledged_signal_file.is_file()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_acknowledge_rename_race(signal_file: &Path, acknowledged_signal_file: &Path) {
    tracing::warn!(
        pending = %signal_file.display(),
        acknowledged = %acknowledged_signal_file.display(),
        "signal file was already moved before acknowledge completed"
    );
}

fn acknowledge_rename_failure(
    signal_file: &Path,
    acknowledged_signal_file: &Path,
    error: &io::Error,
) -> CliError {
    CliErrorKind::workflow_io(format!(
        "move acknowledged signal {} -> {}: {error}",
        signal_file.display(),
        acknowledged_signal_file.display()
    ))
    .into()
}

/// Read all acknowledgment files from the directory.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn read_acknowledgments(signal_dir: &Path) -> Result<Vec<SignalAck>, CliError> {
    read_filtered_json_files(&acknowledged_dir(signal_dir), is_signal_ack_file)
}

/// Return pending signals whose `created_at` is older than `threshold_seconds`.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn check_signal_timeouts(
    signal_dir: &Path,
    threshold_seconds: u64,
) -> Result<Vec<Signal>, CliError> {
    let signals = read_pending_signals(signal_dir)?;
    let now = chrono::Utc::now();
    let mut timed_out = Vec::new();
    for signal in signals {
        let Ok(created) = chrono::DateTime::parse_from_rfc3339(&signal.created_at) else {
            // Unparseable timestamp - treat as timed out
            timed_out.push(signal);
            continue;
        };
        let elapsed = now
            .signed_duration_since(created)
            .num_seconds()
            .unsigned_abs();
        if elapsed >= threshold_seconds {
            timed_out.push(signal);
        }
    }
    Ok(timed_out)
}

/// Clean up all pending signals for a dead agent by acknowledging them as expired.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn cleanup_pending_signals(
    signal_dir: &Path,
    agent_id: &str,
    session_id: &str,
) -> Result<(), CliError> {
    let signals = read_pending_signals(signal_dir)?;
    let now = chrono::Utc::now().to_rfc3339();
    for signal in signals {
        let ack = SignalAck {
            signal_id: signal.signal_id.clone(),
            acknowledged_at: now.clone(),
            result: AckResult::Expired,
            agent: agent_id.to_string(),
            session_id: session_id.to_string(),
            details: Some("agent disconnected by liveness sync".to_string()),
        };
        acknowledge_signal(signal_dir, &ack)?;
    }
    Ok(())
}

/// Read acknowledged signal payloads that have already been moved out of pending.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn read_acknowledged_signals(signal_dir: &Path) -> Result<Vec<Signal>, CliError> {
    read_filtered_json_files(
        &acknowledged_dir(signal_dir),
        is_acknowledged_signal_payload,
    )
}

fn is_signal_ack_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(".ack.json"))
}

fn is_acknowledged_signal_payload(path: &Path) -> bool {
    !is_signal_ack_file(path)
}

fn quarantine_malformed_json_file(path: &Path, error: &serde_json::Error) {
    let quarantine_path = next_quarantine_path(path);
    if let Err(rename_error) = fs::rename(path, &quarantine_path) {
        warn_signal_json_quarantine_failure(path, &quarantine_path, error, &rename_error);
        return;
    }

    warn_signal_json_quarantined(path, &quarantine_path, error);
}

fn next_quarantine_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .map_or_else(|| String::from("malformed.json"), ToString::to_string);
    let mut counter = 0_u32;
    loop {
        let suffix = if counter == 0 {
            String::from(".corrupt")
        } else {
            format!(".corrupt.{counter}")
        };
        let candidate = path.with_file_name(format!("{file_name}{suffix}"));
        if !candidate.exists() {
            return candidate;
        }
        counter = counter.saturating_add(1);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_signal_json_quarantine_failure(
    path: &Path,
    quarantine_path: &Path,
    error: &serde_json::Error,
    rename_error: &io::Error,
) {
    tracing::warn!(
        path = %path.display(),
        quarantine = %quarantine_path.display(),
        parse_error = %error,
        %rename_error,
        "failed to quarantine malformed signal json file"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_signal_json_quarantined(path: &Path, quarantine_path: &Path, error: &serde_json::Error) {
    tracing::warn!(
        path = %path.display(),
        quarantine = %quarantine_path.display(),
        parse_error = %error,
        "quarantined malformed signal json file"
    );
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
    fn read_acknowledgments_ignores_acknowledged_signal_payloads() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        let signal = sample_signal();
        write_signal_file(&signal_dir, &signal).unwrap();

        let ack = SignalAck {
            signal_id: signal.signal_id.clone(),
            acknowledged_at: "2026-03-28T12:00:03Z".into(),
            result: AckResult::Accepted,
            agent: "codex".into(),
            session_id: "sess-1".into(),
            details: None,
        };
        acknowledge_signal(&signal_dir, &ack).unwrap();

        let acknowledgments = read_acknowledgments(&signal_dir).unwrap();
        let acknowledged_signals = read_acknowledged_signals(&signal_dir).unwrap();
        let payload_path = acknowledged_dir(&signal_dir).join("sig-test-001.json");

        assert_eq!(acknowledgments.len(), 1);
        assert_eq!(acknowledged_signals.len(), 1);
        assert!(payload_path.exists());
    }

    #[test]
    fn read_empty_dir_returns_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let signals = read_pending_signals(tmp.path()).unwrap();
        assert!(signals.is_empty());
        let acks = read_acknowledgments(tmp.path()).unwrap();
        assert!(acks.is_empty());
    }

    #[test]
    fn check_signal_timeouts_detects_expired() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");

        // Write a signal with an old created_at timestamp
        let mut signal = sample_signal();
        signal.created_at = "2020-01-01T00:00:00Z".into();
        signal.expires_at = "2020-01-01T00:05:00Z".into();
        write_signal_file(&signal_dir, &signal).unwrap();

        let timed_out = check_signal_timeouts(&signal_dir, 60).unwrap();
        assert_eq!(timed_out.len(), 1);
        assert_eq!(timed_out[0].signal_id, "sig-test-001");
    }

    #[test]
    fn check_signal_timeouts_ignores_fresh_signals() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        let mut signal = sample_signal();
        signal.created_at = chrono::Utc::now().to_rfc3339();
        write_signal_file(&signal_dir, &signal).unwrap();

        let timed_out = check_signal_timeouts(&signal_dir, 600).unwrap();
        assert!(timed_out.is_empty());
    }

    #[test]
    fn cleanup_pending_signals_moves_to_acknowledged() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        write_signal_file(&signal_dir, &sample_signal()).unwrap();

        cleanup_pending_signals(&signal_dir, "dead-agent", "sess-1").unwrap();

        assert!(read_pending_signals(&signal_dir).unwrap().is_empty());
        let acks = read_acknowledgments(&signal_dir).unwrap();
        assert_eq!(acks.len(), 1);
        assert_eq!(acks[0].result, AckResult::Expired);
    }

    #[test]
    fn malformed_pending_signal_is_quarantined() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        let pending = pending_dir(&signal_dir);
        fs::create_dir_all(&pending).unwrap();
        let malformed = pending.join("sig-bad.json");
        fs::write(&malformed, "{ not valid json").unwrap();

        let signals = read_pending_signals(&signal_dir).unwrap();

        assert!(signals.is_empty());
        assert!(
            !malformed.exists(),
            "malformed file should be moved out of pending"
        );
        let quarantined: Vec<_> = fs::read_dir(&pending)
            .unwrap()
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("sig-bad.json.corrupt"))
            })
            .collect();
        assert_eq!(quarantined.len(), 1);
    }

    #[test]
    fn acknowledge_signal_surfaces_rename_failures() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        fs::create_dir_all(pending_dir(&signal_dir)).unwrap();

        let ack = SignalAck {
            signal_id: "sig-test-001".into(),
            acknowledged_at: "2026-03-28T12:00:03Z".into(),
            result: AckResult::Accepted,
            agent: "codex".into(),
            session_id: "sess-1".into(),
            details: None,
        };

        let error = acknowledge_signal(&signal_dir, &ack).unwrap_err();
        assert!(
            error.to_string().contains("move acknowledged signal"),
            "rename failure should be surfaced: {error}"
        );
    }

    #[test]
    fn write_signal_file_rejects_unsafe_signal_id() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        let escaped = tmp.path().join("escape.json");
        let mut signal = sample_signal();
        signal.signal_id = "../../escape".into();

        let error = write_signal_file(&signal_dir, &signal).unwrap_err();

        assert!(
            error.to_string().contains("unsafe name") || error.to_string().contains("unsafe"),
            "{error}"
        );
        assert!(!escaped.exists());
    }

    #[test]
    fn acknowledge_signal_rejects_unsafe_signal_id() {
        let tmp = tempfile::tempdir().unwrap();
        let signal_dir = tmp.path().join("signals");
        let escaped_ack = tmp.path().join("escape.ack.json");

        let ack = SignalAck {
            signal_id: "../../escape".into(),
            acknowledged_at: "2026-03-28T12:00:03Z".into(),
            result: AckResult::Accepted,
            agent: "codex".into(),
            session_id: "sess-1".into(),
            details: None,
        };

        let error = acknowledge_signal(&signal_dir, &ack).unwrap_err();

        assert!(
            error.to_string().contains("unsafe name") || error.to_string().contains("unsafe"),
            "{error}"
        );
        assert!(!escaped_ack.exists());
    }
}
