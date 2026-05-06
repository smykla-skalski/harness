use crate::errors::{CliError, CliErrorKind};
use crate::session::types::RuntimeSessionId;

use super::DiscoveredProject;
use super::sessions::{list_active_session_ids_for_project, load_session_state_for_project};

/// Resolve an orchestration session ID from a runtime session key within one
/// discovered project context.
///
/// Scopes the new-layout scan to the project's bucket when `project.project_dir`
/// is known. Falls back to scanning every project bucket plus the legacy
/// orchestration paths when only the `context_root` is available.
///
/// # Errors
/// Returns `CliError` when session state cannot be loaded or when the runtime
/// session key is ambiguous.
pub fn resolve_session_id_for_runtime_session(
    project: &DiscoveredProject,
    runtime_name: &str,
    runtime_session_id: &str,
) -> Result<Option<String>, CliError> {
    let runtime_session_id = RuntimeSessionId::from(runtime_session_id);
    let mut matches = Vec::new();

    for session_id in list_active_session_ids_for_project(project)? {
        let Some(state) = load_session_state_for_project(project, &session_id)? else {
            continue;
        };
        if state
            .find_session_agent_id_by_runtime_session(runtime_name, &runtime_session_id)
            .is_some()
        {
            matches.push(state.session_id);
        }
    }

    match matches.len() {
        0 => Ok(None),
        1 => Ok(matches.into_iter().next()),
        _ => Err(CliErrorKind::session_ambiguous(format!(
            "runtime session '{}' for runtime '{runtime_name}' maps to multiple orchestration sessions",
            runtime_session_id.as_str()
        ))
        .into()),
    }
}
