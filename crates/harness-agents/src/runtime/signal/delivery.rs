use std::path::Path;

use harness_infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{AckPaths, Signal, SignalAck, read_acknowledgment, write_signal_file};

/// Result of reconciling one durable signal with its runtime file queue.
#[derive(Debug, Clone)]
pub enum SignalFileState {
    Created,
    Pending,
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
