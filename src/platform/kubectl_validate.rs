use std::path::{Path, PathBuf};
use std::{env, fs};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind, io_for};
use crate::workspace::{dirs_home, harness_data_root};

/// Decision about kubectl-validate installation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum KubectlValidateDecision {
    Installed,
    Declined,
}

/// Persisted state for kubectl-validate decision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KubectlValidateState {
    pub schema_version: u32,
    pub decision: KubectlValidateDecision,
    pub decided_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary_path: Option<String>,
}

/// Path to the kubectl-validate state file.
#[must_use]
pub fn kubectl_validate_state_path() -> PathBuf {
    harness_data_root()
        .join("tooling")
        .join("kubectl-validate.json")
}

/// Read kubectl-validate state from disk.
///
/// Returns `None` if the state file does not exist.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn read_kubectl_validate_state() -> Result<Option<KubectlValidateState>, CliError> {
    let path = kubectl_validate_state_path();
    if !path.exists() {
        return Ok(None);
    }
    let text =
        fs::read_to_string(&path).map_err(|e| -> CliError { io_for("read", &path, &e).into() })?;
    let state: KubectlValidateState = serde_json::from_str(&text).map_err(|e| -> CliError {
        CliErrorKind::workflow_parse(format!("failed to parse {}: {e}", path.display())).into()
    })?;
    Ok(Some(state))
}

/// Check if the install prompt is needed.
///
/// Returns true when no binary is found and no decision has been recorded.
///
/// # Errors
/// Returns `CliError` if the state file exists but cannot be read or parsed.
pub fn kubectl_validate_prompt_required() -> Result<bool, CliError> {
    if resolve_kubectl_validate_binary().is_some() {
        return Ok(false);
    }
    let state = read_kubectl_validate_state()?;
    Ok(state.is_none())
}

/// Resolve the kubectl-validate binary path.
///
/// Search order: `HARNESS_KUBECTL_VALIDATE_BIN` env, persisted state,
/// default install locations (`~/.local/bin`, `~/bin`), then `$PATH`.
#[must_use]
pub fn resolve_kubectl_validate_binary() -> Option<PathBuf> {
    // 1. Environment override
    if let Ok(val) = env::var("HARNESS_KUBECTL_VALIDATE_BIN") {
        let trimmed = val.trim();
        if !trimmed.is_empty() {
            let candidate = PathBuf::from(trimmed);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }
    }

    // 2. Persisted state
    if let Ok(Some(state)) = read_kubectl_validate_state()
        && let Some(ref bp) = state.binary_path
    {
        let candidate = PathBuf::from(bp);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }

    // 3. Default install locations
    for candidate in default_install_candidates() {
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }

    // 4. PATH lookup
    which_kubectl_validate()
}

fn default_install_candidates() -> Vec<PathBuf> {
    let home = dirs_home();
    vec![
        home.join(".local").join("bin").join("kubectl-validate"),
        home.join("bin").join("kubectl-validate"),
    ]
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.is_file()
        && path
            .metadata()
            .is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
}

fn which_kubectl_validate() -> Option<PathBuf> {
    let path_env = env::var("PATH").unwrap_or_default();
    for dir in path_env.split(':') {
        if dir.is_empty() {
            continue;
        }
        let candidate = PathBuf::from(dir).join("kubectl-validate");
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests;
