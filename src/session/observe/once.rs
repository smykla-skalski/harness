use std::path::Path;

use crate::errors::CliError;
use crate::observe::types::Issue;
use crate::session::service;

use super::scan::scan_all_agents;
use super::support::{create_work_items_for_issues, emit_results, persist_observer_snapshot};

/// Run a one-shot multi-agent observation scan.
///
/// Scans each registered agent's conversation log using the existing
/// classifier pipeline, merges issues across agents, and creates work
/// items in the session state for new issues.
///
/// # Errors
/// Returns `CliError` if the session is not found or on I/O failures.
pub fn execute_session_observe(
    session_id: &str,
    project_dir: &Path,
    json: bool,
    actor_id: Option<&str>,
) -> Result<i32, CliError> {
    let all_issues = run_session_observe(session_id, project_dir, actor_id)?;
    emit_results(&all_issues, json)
}

/// Run a one-shot observe scan and persist any new work items without emitting CLI output.
///
/// # Errors
/// Returns `CliError` if the session is not found or on I/O failures.
pub(crate) fn run_session_observe(
    session_id: &str,
    project_dir: &Path,
    actor_id: Option<&str>,
) -> Result<Vec<Issue>, CliError> {
    let state = service::session_status(session_id, project_dir)?;
    let all_issues = scan_all_agents(&state, session_id, project_dir)?;
    persist_observer_snapshot(&state, project_dir, &all_issues)?;
    create_work_items_for_issues(&all_issues, session_id, &state, project_dir, actor_id)?;
    Ok(all_issues)
}
