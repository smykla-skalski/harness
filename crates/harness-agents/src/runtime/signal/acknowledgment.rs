use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use harness_infra::persistence::flock::{
    FlockErrorContext, FlockGuard, TryAcquireFlockError, try_acquire_exclusive_flock,
    with_exclusive_flock,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_kernel::io::write_text;

use super::{SignalAck, acknowledged_dir, pending_dir, signal_ack_name, signal_json_name};

#[derive(Debug)]
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

/// A per-signal delivery claim held until the hook output reaches stdout.
#[derive(Debug)]
pub struct PendingSignalDelivery {
    paths: AckPaths,
    acknowledgment: SignalAck,
    acknowledgment_json: String,
    _guard: FlockGuard,
}

impl PendingSignalDelivery {
    /// Return the decision this delivery will commit.
    #[must_use]
    pub fn acknowledgment(&self) -> &SignalAck {
        &self.acknowledgment
    }

    /// Commit the terminal acknowledgment after the hook output is flushed.
    ///
    /// # Errors
    /// Returns `CliError` when the acknowledgment or payload move cannot be persisted.
    pub fn commit(self) -> Result<SignalAck, CliError> {
        write_new_ack_locked(&self.paths, &self.acknowledgment, &self.acknowledgment_json)
    }
}

/// Whether this caller owns delivery, observed its terminal result, or found another live owner.
#[derive(Debug)]
pub enum SignalAckClaim {
    Created(PendingSignalDelivery),
    Existing(SignalAck),
    Busy,
}

/// Claim one signal under its per-signal flock without settling its acknowledgment.
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
    let guard = match try_acquire_exclusive_flock(
        &paths.ack_lock_file,
        FlockErrorContext::new("signal acknowledgment"),
    ) {
        Ok(guard) => guard,
        Err(TryAcquireFlockError::Busy) => return Ok(SignalAckClaim::Busy),
        Err(TryAcquireFlockError::Io(error)) => return Err(error),
    };
    claim_ack_locked(paths, acknowledgment, acknowledgment_json, guard)
}

fn claim_ack_locked(
    paths: AckPaths,
    acknowledgment: &SignalAck,
    acknowledgment_json: String,
    guard: FlockGuard,
) -> Result<SignalAckClaim, CliError> {
    if let Some(existing) = read_existing_ack(&paths, &acknowledgment.signal_id)? {
        return claim_prepared_ack(paths, existing, guard);
    }
    require_pending_signal(&paths)?;
    Ok(SignalAckClaim::Created(PendingSignalDelivery {
        paths,
        acknowledgment: acknowledgment.clone(),
        acknowledgment_json,
        _guard: guard,
    }))
}

/// Decides what an already-written acknowledgment means for a fresh claim.
///
/// A settlement is terminal only once the payload has left `pending`
/// (`acknowledgment_is_terminal`). An acknowledgment whose payload is still
/// pending was prepared by an attempt that died between writing it and getting
/// its output to the agent, so retiring the payload here would settle the
/// signal without anyone ever receiving it - the delivery is lost silently.
/// Recovery re-claims that delivery instead, and commits the decision the first
/// attempt recorded rather than this caller's, because the stored
/// acknowledgment is the one every later reader has already agreed on.
fn claim_prepared_ack(
    paths: AckPaths,
    existing: SignalAck,
    guard: FlockGuard,
) -> Result<SignalAckClaim, CliError> {
    if !pending_signal_exists(&paths)? {
        return Ok(SignalAckClaim::Existing(existing));
    }
    let acknowledgment_json = serde_json::to_string_pretty(&existing)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("ack: {error}")))?;
    Ok(SignalAckClaim::Created(PendingSignalDelivery {
        paths,
        acknowledgment: existing,
        acknowledgment_json,
        _guard: guard,
    }))
}

pub(super) fn write_new_ack_locked(
    paths: &AckPaths,
    acknowledgment: &SignalAck,
    acknowledgment_json: &str,
) -> Result<SignalAck, CliError> {
    require_pending_signal(paths)?;
    write_text(&paths.ack_file, acknowledgment_json)?;
    move_acknowledged_signal(&paths.signal_file, &paths.acknowledged_signal_file)?;
    Ok(acknowledgment.clone())
}

fn require_pending_signal(paths: &AckPaths) -> Result<(), CliError> {
    if pending_signal_exists(paths)? {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "pending signal '{}' is missing",
        paths.signal_file.display()
    ))
    .into())
}

pub(super) fn read_existing_ack(
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
    Ok(Some(existing))
}

pub(super) fn pending_signal_exists(paths: &AckPaths) -> Result<bool, CliError> {
    paths.signal_file.try_exists().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect pending signal '{}': {error}",
            paths.signal_file.display()
        ))
        .into()
    })
}

pub(super) fn move_pending_if_present(paths: &AckPaths) -> Result<(), CliError> {
    if pending_signal_exists(paths)? {
        move_acknowledged_signal(&paths.signal_file, &paths.acknowledged_signal_file)?;
    }
    Ok(())
}

pub(super) fn acknowledgment_is_terminal(
    signal_dir: &Path,
    signal_id: &str,
) -> Result<bool, CliError> {
    let paths = AckPaths::new(signal_dir, signal_id)?;
    Ok(!pending_signal_exists(&paths)?)
}

/// Acknowledge a signal and return the first equivalent acknowledgment stored.
///
/// # Errors
/// Returns `CliError` on filesystem failures or a conflicting acknowledgment.
pub fn acknowledge_signal_once(signal_dir: &Path, ack: &SignalAck) -> Result<SignalAck, CliError> {
    let paths = AckPaths::new(signal_dir, &ack.signal_id)?;
    fs::create_dir_all(&paths.acknowledged_dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("create ack dir: {error}")))?;
    let ack_json = serde_json::to_string_pretty(ack)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("ack: {error}")))?;
    with_exclusive_flock(
        &paths.ack_lock_file,
        FlockErrorContext::new("signal acknowledgment"),
        || acknowledge_signal_once_locked(&paths, ack, &ack_json),
    )
}

fn acknowledge_signal_once_locked(
    paths: &AckPaths,
    requested: &SignalAck,
    requested_json: &str,
) -> Result<SignalAck, CliError> {
    let Some(existing) = read_existing_ack(paths, &requested.signal_id)? else {
        return write_new_ack_locked(paths, requested, requested_json);
    };
    let stored = existing;
    move_pending_if_present(paths)?;
    if !acknowledgments_match(&stored, requested) {
        return Err(acknowledgment_conflict(&requested.signal_id));
    }
    Ok(stored)
}

fn acknowledgment_conflict(signal_id: &str) -> CliError {
    CliErrorKind::session_agent_conflict(format!(
        "signal '{signal_id}' already has a different runtime acknowledgment"
    ))
    .into()
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
