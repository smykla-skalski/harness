use std::sync::{LazyLock, Mutex};

use harness_kernel::errors::CliError;
use harness_telemetry::{RepeatedLogGate, log_identity};

use crate::workspace::utc_now;

use super::AcpAgentInspectResponse;

static INSPECT_FAILURE_LOG_GATE: LazyLock<Mutex<RepeatedLogGate>> =
    LazyLock::new(|| Mutex::new(RepeatedLogGate::default()));

pub(super) fn log_empty_inspect_with_error(
    error: &CliError,
    message: &str,
) -> AcpAgentInspectResponse {
    let identity = log_identity(&(error.code(), error.to_string(), message));
    let should_warn = INSPECT_FAILURE_LOG_GATE
        .lock()
        .map_or(true, |mut gate| gate.should_warn(identity));
    if should_warn {
        tracing::warn!(%error, "{message}");
    } else {
        tracing::debug!(%error, "{message}");
    }
    AcpAgentInspectResponse {
        agents: Vec::new(),
        daemon_perceived_now: Some(utc_now()),
        available: false,
        issue_message: Some(message.to_string()),
    }
}

#[cfg(test)]
pub(super) fn inspect_failure_warning_is_due(
    gate: &mut RepeatedLogGate,
    error: &CliError,
    message: &str,
) -> bool {
    gate.should_warn(log_identity(&(error.code(), error.to_string(), message)))
}
