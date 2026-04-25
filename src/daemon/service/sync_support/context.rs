use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::session::{storage as session_storage, types::SessionState};

use super::{CliError, CliErrorKind, HookAgent, Path, PathBuf, ResolvedSession};

pub(crate) fn resolve_hook_agent(runtime_name: &str) -> Option<HookAgent> {
    match runtime_name {
        "claude" => Some(HookAgent::Claude),
        "copilot" => Some(HookAgent::Copilot),
        "codex" => Some(HookAgent::Codex),
        "gemini" => Some(HookAgent::Gemini),
        "vibe" => Some(HookAgent::Vibe),
        "opencode" => Some(HookAgent::OpenCode),
        _ => None,
    }
}

pub(crate) fn session_not_found(session_id: &str) -> CliError {
    CliErrorKind::session_not_active(format!("session '{session_id}' not found")).into()
}

pub(crate) fn project_dir_for_db_session(
    db: &DaemonDb,
    session_id: &str,
) -> Result<PathBuf, CliError> {
    if let Some(project_dir) = db.project_dir_for_session(session_id)? {
        return Ok(PathBuf::from(project_dir));
    }

    let resolved = db
        .resolve_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    Ok(effective_project_dir(&resolved).to_path_buf())
}

/// Return the original project directory when available, falling back to the
/// context root. This is safe because `project_context_dir` is idempotent
/// for paths already under the projects root.
pub(crate) fn effective_project_dir(resolved: &ResolvedSession) -> &Path {
    resolved
        .project
        .project_dir
        .as_deref()
        .unwrap_or(&resolved.project.context_root)
}

pub(crate) fn sync_file_state(project_dir: &Path, state: &SessionState) -> Result<(), CliError> {
    let layout = session_storage::layout_from_project_dir(project_dir, &state.session_id)?;
    session_storage::save_state(&layout, state)
}

pub(crate) fn sync_file_state_for_resolved(resolved: &ResolvedSession) -> Result<(), CliError> {
    sync_file_state(effective_project_dir(resolved), &resolved.state)
}

pub(crate) async fn sync_file_state_from_async_db(
    async_db: &AsyncDaemonDb,
    session_id: &str,
) -> Result<(), CliError> {
    let resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    sync_file_state_for_resolved(&resolved)
}
