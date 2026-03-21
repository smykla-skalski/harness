use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::kernel::skills::dirs as skill_dirs;
use crate::workspace::{session_context_dir, utc_now};

/// Active create session state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateSession {
    pub repo_root: String,
    pub feature: String,
    pub mode: String,
    pub suite_name: String,
    pub suite_dir: String,
    pub updated_at: String,
}

impl CreateSession {
    #[must_use]
    pub fn suite_path(&self) -> PathBuf {
        PathBuf::from(&self.suite_dir).join("suite.md")
    }
}

fn session_file_path() -> Result<PathBuf, CliError> {
    Ok(create_workspace_dir()?.join("session.json"))
}

/// Load the current create session from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_create_session() -> Result<Option<CreateSession>, CliError> {
    let path = session_file_path()?;
    if !path.exists() {
        return Ok(None);
    }
    let session: CreateSession = read_json_typed(&path).map_err(|e| {
        CliErrorKind::create_payload_invalid("session", "parse failed").with_details(e.to_string())
    })?;
    Ok(Some(session))
}

/// Save an create session to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn save_create_session(session: &CreateSession) -> Result<CreateSession, CliError> {
    let path = session_file_path()?;
    write_json_pretty(&path, session).map_err(|e| {
        CliErrorKind::create_payload_invalid("session", "write failed").with_details(e.to_string())
    })?;
    Ok(session.clone())
}

/// Require an active create session.
///
/// # Errors
/// Returns `CliError` if no session is active.
pub fn require_create_session() -> Result<CreateSession, CliError> {
    let session = load_create_session()?;
    session.ok_or_else(|| CliErrorKind::CreateSessionMissing.into())
}

/// Begin a new create session.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn begin_create_session(
    repo_root: &Path,
    feature: &str,
    mode: &str,
    suite_dir: &Path,
    suite_name: &str,
) -> Result<CreateSession, CliError> {
    if suite_dir.join("suite.md").exists() {
        return Err(CliErrorKind::create_suite_dir_exists(suite_dir.display().to_string()).into());
    }
    let session = CreateSession {
        repo_root: repo_root
            .canonicalize()
            .unwrap_or_else(|_| repo_root.to_path_buf())
            .to_string_lossy()
            .to_string(),
        feature: feature.to_string(),
        mode: mode.to_string(),
        suite_name: suite_name.to_string(),
        suite_dir: suite_dir
            .canonicalize()
            .unwrap_or_else(|_| suite_dir.to_path_buf())
            .to_string_lossy()
            .to_string(),
        updated_at: utc_now(),
    };
    save_create_session(&session)
}

/// Workspace directory for create artifacts.
///
/// # Errors
/// Returns `CliError` if the session context directory cannot be determined.
pub fn create_workspace_dir() -> Result<PathBuf, CliError> {
    Ok(session_context_dir()?.join(skill_dirs::CREATE_WORKSPACE))
}
