use std::path::Path;

use crate::workspace::harness_data_root;
use crate::workspace::layout::{SessionLayout, sessions_root};
use crate::workspace::project_resolver::resolve_name;
use harness_kernel::errors::CliError;

pub(super) fn deterministic_session_layout(
    origin: &Path,
    session_id: &str,
) -> Result<SessionLayout, CliError> {
    let canonical_origin = origin.canonicalize().map_err(|error| {
        super::workflow_io(format!("canonicalize remote cleanup origin: {error}"))
    })?;
    let sessions_root = sessions_root(&harness_data_root());
    let project_name = resolve_name(&canonical_origin, &sessions_root)
        .map_err(|error| super::workflow_io(format!("resolve remote cleanup project: {error}")))?;
    Ok(SessionLayout {
        sessions_root,
        project_name,
        session_id: session_id.into(),
    })
}

pub(super) fn cleanup_layout(
    project_dir: &str,
    session_id: &str,
) -> Result<SessionLayout, CliError> {
    let workspace = Path::new(project_dir);
    let session_dir = workspace
        .parent()
        .filter(|_| {
            workspace
                .file_name()
                .is_some_and(|name| name == "workspace")
        })
        .ok_or_else(|| {
            super::concurrent("remote executor cleanup worktree path is not canonical")
        })?;
    if session_dir.file_name().and_then(|name| name.to_str()) != Some(session_id) {
        return Err(super::concurrent(
            "remote executor cleanup worktree does not match its session",
        ));
    }
    let project = session_dir.parent().ok_or_else(|| {
        super::concurrent("remote executor cleanup session has no project directory")
    })?;
    let sessions_root = project
        .parent()
        .ok_or_else(|| super::concurrent("remote executor cleanup session has no sessions root"))?;
    let project_name = project
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| super::concurrent("remote executor cleanup project name is invalid"))?;
    let layout = SessionLayout {
        sessions_root: sessions_root.into(),
        project_name: project_name.into(),
        session_id: session_id.into(),
    };
    if layout.workspace() != workspace {
        return Err(super::concurrent(
            "remote executor cleanup worktree path is not normalized",
        ));
    }
    Ok(layout)
}
