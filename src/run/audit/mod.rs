use std::path::Path;

use serde::Serialize;

use crate::hooks::audit::{AuditAppendRequest, append_audit_entry};
use crate::run::RunStatus;
use crate::run::context::RunLayout;
use crate::run::workflow::{RunnerPhase, RunnerWorkflowState};
use harness_kernel::errors::{CliError, CliErrorKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditPhaseContext {
    pub phase: String,
    pub group_id: Option<String>,
}

impl AuditPhaseContext {
    #[must_use]
    pub fn new(phase: String, group_id: Option<String>) -> Self {
        Self { phase, group_id }
    }
}

/// Resolve audit phase and optional execution group from workflow state.
#[must_use]
pub fn resolve_phase_context(
    runner_state: Option<&RunnerWorkflowState>,
    run_status: Option<&RunStatus>,
    explicit_phase: Option<&str>,
    explicit_group_id: Option<&str>,
) -> AuditPhaseContext {
    let phase = explicit_phase.map_or_else(
        || {
            runner_state.map_or_else(
                || RunnerPhase::Bootstrap.to_string(),
                |state| state.phase().to_string(),
            )
        },
        str::to_string,
    );

    let group_id = if phase == RunnerPhase::Execution.to_string() {
        explicit_group_id
            .map(str::to_string)
            .or_else(|| run_status.and_then(|status| status.next_planned_group.clone()))
            .or_else(|| run_status.and_then(|status| status.last_completed_group.clone()))
    } else {
        None
    };

    AuditPhaseContext::new(phase, group_id)
}

/// Append an audit entry after `suite-run-state.json` is written.
///
/// # Errors
/// Returns `CliError` on serialization or audit failure.
pub fn append_runner_state_audit(
    run_dir: &Path,
    state: &RunnerWorkflowState,
) -> Result<(), CliError> {
    let serialized = serialize_json(state, "runner state")?;
    let phase_name = state.phase().to_string();
    let run_status = load_run_status(run_dir)?;
    let phase_context =
        resolve_phase_context(Some(state), run_status.as_ref(), Some(&phase_name), None);
    append_audit_entry(AuditAppendRequest {
        run_dir: run_dir.to_path_buf(),
        tool_name: "RunnerStateWrite".to_string(),
        tool_input: "suite-run-state.json".to_string(),
        full_output: format!("{serialized}\n"),
        phase: phase_context.phase,
        group_id: phase_context.group_id,
    })?;
    Ok(())
}

fn load_run_status(run_dir: &Path) -> Result<Option<RunStatus>, CliError> {
    let path = RunLayout::from_run_dir(run_dir).status_path();
    if !path.exists() {
        return Ok(None);
    }
    RunStatus::load(&path).map(Some)
}

fn serialize_json<T>(value: &T, label: &str) -> Result<String, CliError>
where
    T: Serialize,
{
    serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::serialize(format!("{label}: {error}")).into())
}

#[cfg(all(test, not(feature = "standalone-worker")))]
mod tests;
