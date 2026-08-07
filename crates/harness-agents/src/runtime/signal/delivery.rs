use std::fs;
use std::path::Path;

use harness_infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{
    AckPaths, Signal, SignalAck, move_acknowledged_signal, read_acknowledgment, write_ack_locked,
    write_signal_file,
};

/// Result of reconciling one durable signal with its runtime file queue.
#[derive(Debug, Clone)]
pub enum SignalFileState {
    Created,
    Pending,
    Acknowledged(SignalAck),
}

/// Result of settling a signal only when its runtime queue already knows about it.
#[derive(Debug, Clone)]
pub enum SignalSettlement {
    Missing,
    Acknowledged(SignalAck),
}

/// Ensure a durable signal is present unless the runtime already acknowledged it.
///
/// The acknowledgment lock closes the race between recreating a missing pending file and the runtime moving that file into the acknowledged directory.
///
/// # Errors
/// Returns `CliError` on filesystem, locking, or serialization failures.
pub fn ensure_signal_file(signal_dir: &Path, signal: &Signal) -> Result<SignalFileState, CliError> {
    let paths = AckPaths::new(signal_dir, &signal.signal_id)?;
    with_exclusive_flock(
        &paths.ack_lock_file,
        FlockErrorContext::new("signal delivery"),
        || {
            if paths.ack_file.try_exists().map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "inspect signal acknowledgment '{}': {error}",
                    paths.ack_file.display()
                ))
            })? {
                let acknowledgment = read_acknowledgment(&paths.ack_file)?;
                if acknowledgment.signal_id != signal.signal_id {
                    return Err(CliErrorKind::session_agent_conflict(format!(
                        "signal '{}' has a mismatched runtime acknowledgment",
                        signal.signal_id
                    ))
                    .into());
                }
                return Ok(SignalFileState::Acknowledged(acknowledgment));
            }
            let existed = paths.signal_file.try_exists().map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "inspect pending signal '{}': {error}",
                    paths.signal_file.display()
                ))
            })?;
            write_signal_file(signal_dir, signal)?;
            Ok(if existed {
                SignalFileState::Pending
            } else {
                SignalFileState::Created
            })
        },
    )
}

/// Acknowledge an existing pending signal or return its first acknowledgment without recreating a
/// missing pending payload.
///
/// # Errors
/// Returns `CliError` on filesystem, locking, serialization, or identity failures.
pub fn settle_signal_if_present(
    signal_dir: &Path,
    acknowledgment: &SignalAck,
) -> Result<SignalSettlement, CliError> {
    let paths = AckPaths::new(signal_dir, &acknowledgment.signal_id)?;
    fs::create_dir_all(&paths.acknowledged_dir)
        .map_err(|error| CliErrorKind::workflow_io(format!("create ack dir: {error}")))?;
    with_exclusive_flock(
        &paths.ack_lock_file,
        FlockErrorContext::new("signal settlement"),
        || settle_locked(&paths, acknowledgment),
    )
}

fn settle_locked(
    paths: &AckPaths,
    acknowledgment: &SignalAck,
) -> Result<SignalSettlement, CliError> {
    if paths.ack_file.try_exists().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect signal acknowledgment '{}': {error}",
            paths.ack_file.display()
        ))
    })? {
        let existing = read_acknowledgment(&paths.ack_file)?;
        if existing.signal_id != acknowledgment.signal_id {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "signal '{}' has a mismatched runtime acknowledgment",
                acknowledgment.signal_id
            ))
            .into());
        }
        if paths.signal_file.try_exists().map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "inspect pending signal '{}': {error}",
                paths.signal_file.display()
            ))
        })? {
            move_acknowledged_signal(&paths.signal_file, &paths.acknowledged_signal_file)?;
        }
        return Ok(SignalSettlement::Acknowledged(existing));
    }
    if !paths.signal_file.try_exists().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "inspect pending signal '{}': {error}",
            paths.signal_file.display()
        ))
    })? {
        return Ok(SignalSettlement::Missing);
    }
    let acknowledgment_json = serde_json::to_string_pretty(acknowledgment)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("ack: {error}")))?;
    let stored = write_ack_locked(paths, acknowledgment, &acknowledgment_json)?;
    move_acknowledged_signal(&paths.signal_file, &paths.acknowledged_signal_file)?;
    Ok(SignalSettlement::Acknowledged(stored))
}
