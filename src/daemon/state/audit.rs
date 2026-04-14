use std::fs;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt;

use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;
use crate::workspace::utc_now;

use super::{
    DaemonAuditEvent, DaemonDiagnostics, auth_token_path, daemon_root, ensure_daemon_dirs,
    events_path, manifest_path,
};

pub fn ensure_auth_token() -> Result<String, CliError> {
    ensure_daemon_dirs()?;
    let path = auth_token_path();
    if path.is_file() {
        return fs_err::read_to_string(&path)
            .map(|token| token.trim().to_string())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("read daemon token: {error}")).into()
            });
    }

    let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    write_text(&path, &token)?;
    let permissions = fs::Permissions::from_mode(0o600);
    fs::set_permissions(&path, permissions).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "set daemon token permissions: {error}"
        )))
    })?;
    Ok(token)
}

pub fn append_event(level: &str, message: &str) -> Result<(), CliError> {
    ensure_daemon_dirs()?;
    let path = events_path();
    let event = DaemonAuditEvent {
        recorded_at: utc_now(),
        level: level.to_string(),
        message: message.to_string(),
    };
    let line = serde_json::to_string(&event).map_err(|error| {
        CliError::from(CliErrorKind::workflow_serialize(format!(
            "serialize daemon audit event: {error}"
        )))
    })?;
    let mut file = fs_err::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| CliErrorKind::workflow_io(format!("open daemon events: {error}")))?;
    writeln!(file, "{line}")
        .map_err(|error| CliErrorKind::workflow_io(format!("append daemon event: {error}")).into())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tiny fallback path only looks complex because of tracing macros"
)]
pub fn append_event_best_effort(level: &str, message: &str) {
    if let Err(error) = append_event(level, message) {
        tracing::warn!(
            %error,
            level,
            event_message = message,
            "failed to append daemon audit event"
        );
    }
}

pub fn read_recent_events(limit: usize) -> Result<Vec<DaemonAuditEvent>, CliError> {
    let path = events_path();
    if limit == 0 || !path.is_file() {
        return Ok(Vec::new());
    }

    let content = fs_err::read_to_string(&path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "read daemon events {}: {error}",
            path.display()
        )))
    })?;
    let mut events = Vec::new();
    for line in content.lines().rev() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let event = serde_json::from_str(trimmed).map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "parse daemon event {}: {error}",
                path.display()
            )))
        })?;
        events.push(event);
        if events.len() == limit {
            break;
        }
    }
    events.reverse();
    Ok(events)
}

pub fn diagnostics() -> Result<DaemonDiagnostics, CliError> {
    let db_path = daemon_root().join("harness.db");
    let db_size = db_path.metadata().map_or(0, |metadata| metadata.len());
    Ok(DaemonDiagnostics {
        daemon_root: daemon_root().display().to_string(),
        manifest_path: manifest_path().display().to_string(),
        auth_token_path: auth_token_path().display().to_string(),
        auth_token_present: auth_token_path().is_file(),
        events_path: events_path().display().to_string(),
        database_path: db_path.display().to_string(),
        database_size_bytes: db_size,
        last_event: latest_event()?,
    })
}

fn latest_event() -> Result<Option<DaemonAuditEvent>, CliError> {
    Ok(read_recent_events(1)?.pop())
}
