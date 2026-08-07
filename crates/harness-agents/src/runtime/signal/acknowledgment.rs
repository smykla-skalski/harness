use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use harness_infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_kernel::io::write_text;

use super::{SignalAck, acknowledged_dir, pending_dir, signal_ack_name, signal_json_name};

pub(super) struct AckPaths {
    pub(super) acknowledged_dir: PathBuf,
    pub(super) signal_file: PathBuf,
    pub(super) ack_file: PathBuf,
    pub(super) ack_lock_file: PathBuf,
    pub(super) acknowledged_signal_file: PathBuf,
}

impl AckPaths {
    pub(super) fn new(signal_dir: &Path, signal_id: &str) -> Result<Self, CliError> {
        let acknowledged_dir = acknowledged_dir(signal_dir);
        Ok(Self {
            acknowledged_dir: acknowledged_dir.clone(),
            signal_file: pending_dir(signal_dir).join(signal_json_name(signal_id)?),
            ack_file: acknowledged_dir.join(signal_ack_name(signal_id)?),
            ack_lock_file: acknowledged_dir.join(format!("{signal_id}.ack.lock")),
            acknowledged_signal_file: acknowledged_dir.join(signal_json_name(signal_id)?),
        })
    }
}

/// Whether this caller created the terminal acknowledgment or observed the first writer's result.
#[derive(Debug, Clone)]
pub enum SignalAckClaim {
    Created(SignalAck),
    Existing(SignalAck),
}

/// Claim and settle one signal acknowledgment under its per-signal flock.
///
/// # Errors
/// Returns `CliError` on missing payloads, filesystem failures, or invalid identities.
pub fn claim_signal_acknowledgment(
    signal_dir: &Path,
    acknowledgment: &SignalAck,
) -> Result<SignalAckClaim, CliError> {
    let paths = AckPaths::new(signal_dir, &acknowledgment.signal_id)?;
    fs::create_dir_all(&paths.acknowledged_dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("create ack dir: {error}")))?;
    let acknowledgment_json = serde_json::to_string_pretty(acknowledgment)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("ack: {error}")))?;
    with_exclusive_flock(
        &paths.ack_lock_file,
        FlockErrorContext::new("signal acknowledgment"),
        || claim_ack_locked(&paths, acknowledgment, &acknowledgment_json),
    )
}

pub(super) fn claim_ack_locked(
    paths: &AckPaths,
    acknowledgment: &SignalAck,
    acknowledgment_json: &str,
) -> Result<SignalAckClaim, CliError> {
    if let Some(existing) = read_existing_ack_and_repair(paths, &acknowledgment.signal_id)? {
        return Ok(SignalAckClaim::Existing(existing));
    }
    if !paths.signal_file.try_exists().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect pending signal '{}': {error}",
            paths.signal_file.display()
        ))
    })? {
        return Err(CliErrorKind::workflow_io(format!(
            "pending signal '{}' is missing",
            paths.signal_file.display()
        ))
        .into());
    }
    write_text(&paths.ack_file, acknowledgment_json)?;
    move_acknowledged_signal(&paths.signal_file, &paths.acknowledged_signal_file)?;
    Ok(SignalAckClaim::Created(acknowledgment.clone()))
}

pub(super) fn read_existing_ack_and_repair(
    paths: &AckPaths,
    signal_id: &str,
) -> Result<Option<SignalAck>, CliError> {
    if !paths.ack_file.try_exists().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect signal acknowledgment '{}': {error}",
            paths.ack_file.display()
        ))
    })? {
        return Ok(None);
    }
    let existing = read_acknowledgment(&paths.ack_file)?;
    if existing.signal_id != signal_id {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "signal '{signal_id}' has a mismatched runtime acknowledgment"
        ))
        .into());
    }
    move_pending_if_present(paths)?;
    Ok(Some(existing))
}

pub(super) fn move_pending_if_present(paths: &AckPaths) -> Result<(), CliError> {
    if paths.signal_file.try_exists().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect pending signal '{}': {error}",
            paths.signal_file.display()
        ))
    })? {
        move_acknowledged_signal(&paths.signal_file, &paths.acknowledged_signal_file)?;
    }
    Ok(())
}

pub(super) fn reconcile_pending_signal(
    signal_dir: &Path,
    signal_id: &str,
) -> Result<bool, CliError> {
    let paths = AckPaths::new(signal_dir, signal_id)?;
    fs::create_dir_all(&paths.acknowledged_dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("create ack dir: {error}")))?;
    with_exclusive_flock(
        &paths.ack_lock_file,
        FlockErrorContext::new("pending signal read"),
        || Ok(read_existing_ack_and_repair(&paths, signal_id)?.is_none()),
    )
}

/// Acknowledge a signal and return the first equivalent acknowledgment stored.
///
/// # Errors
/// Returns `CliError` on filesystem failures or a conflicting acknowledgment.
pub fn acknowledge_signal_once(signal_dir: &Path, ack: &SignalAck) -> Result<SignalAck, CliError> {
    match claim_signal_acknowledgment(signal_dir, ack)? {
        SignalAckClaim::Created(stored) => Ok(stored),
        SignalAckClaim::Existing(stored) if acknowledgments_match(&stored, ack) => Ok(stored),
        SignalAckClaim::Existing(_) => Err(CliErrorKind::session_agent_conflict(format!(
            "signal '{}' already has a different runtime acknowledgment",
            ack.signal_id
        ))
        .into()),
    }
}

/// Acknowledge a signal: write its ack and move its payload to acknowledged storage.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn acknowledge_signal(signal_dir: &Path, ack: &SignalAck) -> Result<(), CliError> {
    acknowledge_signal_once(signal_dir, ack).map(|_| ())
}

/// Return whether two acknowledgments represent the same terminal decision.
#[must_use]
pub fn acknowledgments_match(left: &SignalAck, right: &SignalAck) -> bool {
    left.signal_id == right.signal_id
        && left.result == right.result
        && left.agent == right.agent
        && left.session_id == right.session_id
        && left.details == right.details
}

fn read_acknowledgment(path: &Path) -> Result<SignalAck, CliError> {
    let existing_json = fs::read_to_string(path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read existing signal acknowledgment '{}': {error}",
            path.display()
        ))
    })?;
    serde_json::from_str(&existing_json).map_err(|error| {
        CliErrorKind::workflow_serialize(format!(
            "existing signal acknowledgment '{}': {error}",
            path.display()
        ))
        .into()
    })
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

#[allow(
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
