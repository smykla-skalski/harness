use std::path::Path;

use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;

/// Liveness status for an agent session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivenessStatus {
    /// Agent is actively using tools (activity within active threshold).
    Active,
    /// Agent has recent activity but not within the active threshold.
    Idle,
    /// No activity detected within the timeout period.
    Unresponsive,
}

/// Configuration for liveness detection thresholds.
pub struct LivenessConfig {
    /// Activity within this many seconds means "active" (default: 30).
    pub active_threshold_seconds: u64,
    /// No activity beyond this many seconds means "unresponsive" (default: 300).
    pub unresponsive_timeout_seconds: u64,
}

impl Default for LivenessConfig {
    fn default() -> Self {
        Self {
            active_threshold_seconds: 30,
            unresponsive_timeout_seconds: 300,
        }
    }
}

/// Determine the liveness status from a last-activity timestamp string.
///
/// Returns `Unresponsive` if the timestamp is `None` or unparseable.
#[must_use]
pub fn liveness_from_timestamp(
    last_activity: Option<&str>,
    config: &LivenessConfig,
) -> LivenessStatus {
    let Some(timestamp) = last_activity else {
        return LivenessStatus::Unresponsive;
    };
    let Ok(activity_time) = chrono::DateTime::parse_from_rfc3339(timestamp) else {
        return LivenessStatus::Unresponsive;
    };

    let elapsed = chrono::Utc::now()
        .signed_duration_since(activity_time)
        .num_seconds()
        .unsigned_abs();

    if elapsed < config.active_threshold_seconds {
        LivenessStatus::Active
    } else if elapsed < config.unresponsive_timeout_seconds {
        LivenessStatus::Idle
    } else {
        LivenessStatus::Unresponsive
    }
}

/// Determine the liveness status of an agent session.
///
/// # Errors
/// Returns `CliError` on filesystem failures when checking activity timestamps.
pub fn check_liveness(
    agent: HookAgent,
    project_dir: &Path,
    session_id: &str,
    config: &LivenessConfig,
) -> Result<LivenessStatus, CliError> {
    let runtime = super::runtime_for(agent);
    let last = runtime.last_activity(project_dir, session_id)?;
    Ok(liveness_from_timestamp(last.as_deref(), config))
}
