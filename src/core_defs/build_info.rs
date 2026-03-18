use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use crate::errors::{CliError, CliErrorKind, cow};

/// Build information resolved from the repo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildInfo {
    pub version: String,
}

impl BuildInfo {
    #[must_use]
    pub fn env(&self) -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("BUILD_INFO_VERSION".into(), self.version.clone());
        m
    }
}

/// Result of running an external command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    pub args: Vec<String>,
    pub returncode: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Resolve build info from a repo path.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn resolve_build_info(repo: &Path) -> Result<BuildInfo, CliError> {
    let version_script = repo.join("tools").join("releases").join("version.sh");
    if version_script.exists()
        && let Ok(output) = Command::new(&version_script).current_dir(repo).output()
        && output.status.success()
    {
        let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !version.is_empty() {
            return Ok(BuildInfo { version });
        }
    }

    let dirty_output = Command::new("git")
        .args(["status", "--porcelain", "--untracked-files=no"])
        .current_dir(repo)
        .output()
        .map_err(|e| CliError::from(CliErrorKind::command_failed(cow!("git status: {e}"))))?;

    let dirty = String::from_utf8_lossy(&dirty_output.stdout)
        .trim()
        .to_string();

    if !dirty.is_empty() {
        return Ok(BuildInfo {
            version: "0.0.0-preview.vlocal-build".into(),
        });
    }

    let sha_output = Command::new("git")
        .args(["rev-parse", "--short=10", "HEAD"])
        .current_dir(repo)
        .output()
        .map_err(|e| CliError::from(CliErrorKind::command_failed(cow!("git rev-parse: {e}"))))?;

    let short_sha = String::from_utf8_lossy(&sha_output.stdout)
        .trim()
        .to_string();

    Ok(BuildInfo {
        version: format!("0.0.0-preview.v{short_sha}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_info_env() {
        let info = BuildInfo {
            version: "1.2.3".into(),
        };
        let env = info.env();
        assert_eq!(env.len(), 1);
        assert_eq!(env.get("BUILD_INFO_VERSION").unwrap(), "1.2.3");
    }

    #[test]
    fn resolve_build_info_in_current_repo() {
        let repo = std::env::current_dir().unwrap();
        let info = resolve_build_info(&repo);
        // Skip if git is not available in this environment
        if let Err(ref e) = info
            && e.message().contains("No such file or directory")
        {
            eprintln!("Skipping: git not available in subprocess PATH");
            return;
        }
        assert!(info.is_ok(), "expected Ok, got: {info:?}");
        let info = info.unwrap();
        assert!(!info.version.is_empty(), "version should not be empty");
    }
}
