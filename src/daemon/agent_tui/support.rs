use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::daemon::db::DaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::SessionState;
use crate::workspace::project_context_dir;

pub(super) type Shared<T> = Arc<Mutex<T>>;

pub(super) fn lock<'a, T>(mutex: &'a Mutex<T>, name: &str) -> Result<MutexGuard<'a, T>, CliError> {
    mutex
        .lock()
        .map_err(|error| CliErrorKind::workflow_io(format!("{name} lock poisoned: {error}")).into())
}

pub(super) fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

pub(super) struct ResolvedTuiProject {
    pub(super) project_dir: PathBuf,
    pub(super) context_root: PathBuf,
}

pub(super) fn resolve_tui_project(
    db: &DaemonDb,
    session_id: &str,
    project_dir: Option<&str>,
) -> Result<ResolvedTuiProject, CliError> {
    if let Some(project_dir) = project_dir.filter(|value| !value.trim().is_empty()) {
        let project_dir = PathBuf::from(project_dir);
        return Ok(ResolvedTuiProject {
            context_root: project_context_dir(&project_dir),
            project_dir,
        });
    }

    let resolved = db.resolve_session(session_id)?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("session '{session_id}' not found"))
    })?;
    let context_root = resolved.project.context_root;
    let project_dir = resolved
        .project
        .project_dir
        .or(resolved.project.repository_root)
        .unwrap_or_else(|| context_root.clone());
    Ok(ResolvedTuiProject {
        project_dir,
        context_root,
    })
}

pub(super) fn agent_id_for_tui(
    state: &SessionState,
    marker_capability: &str,
) -> Result<String, CliError> {
    state
        .agents
        .values()
        .find(|agent| {
            agent
                .capabilities
                .iter()
                .any(|capability| capability == marker_capability)
        })
        .map(|agent| agent.agent_id.clone())
        .ok_or_else(|| {
            CliErrorKind::workflow_io(format!(
                "joined agent missing TUI marker capability '{marker_capability}'"
            ))
            .into()
        })
}

pub(super) fn transcript_path(context_root: &Path, runtime: &str, tui_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("tui")
        .join(runtime)
        .join(tui_id)
        .join("output.raw")
}

pub(super) fn persist_transcript(
    path: &Path,
    transcript: &[u8],
    persisted_len: &mut usize,
) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs_err::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!("create agent TUI transcript dir: {error}"))
        })?;
    }

    if transcript.len() < *persisted_len {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write agent TUI transcript: {error}"))
        })?;
        *persisted_len = transcript.len();
        return Ok(());
    }

    if transcript.len() == *persisted_len {
        if *persisted_len == 0 && !path.exists() {
            fs_err::write(path, transcript).map_err(|error| {
                CliErrorKind::workflow_io(format!("write agent TUI transcript: {error}"))
            })?;
        }
        return Ok(());
    }

    if *persisted_len == 0 || !path.exists() {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write agent TUI transcript: {error}"))
        })?;
    } else {
        let mut file = fs_err::OpenOptions::new()
            .append(true)
            .create(true)
            .open(path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("open agent TUI transcript: {error}"))
            })?;
        file.write_all(&transcript[*persisted_len..])
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("append agent TUI transcript: {error}"))
            })?;
    }

    *persisted_len = transcript.len();
    Ok(())
}
