use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use crate::errors::{CliError, CliErrorKind};

/// Build information resolved from the repo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildInfo {
    pub version: String,
}

impl BuildInfo {
    #[must_use]
    pub fn env(&self) -> HashMap<String, String> {
        let mut env = HashMap::new();
        env.insert("BUILD_INFO_VERSION".into(), self.version.clone());
        env
    }
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
        .map_err(|error| {
            CliError::from(CliErrorKind::command_failed(format!("git status: {error}")))
        })?;

    if !String::from_utf8_lossy(&dirty_output.stdout).trim().is_empty() {
        return Ok(BuildInfo {
            version: "0.0.0-preview.vlocal-build".into(),
        });
    }

    let sha_output = Command::new("git")
        .args(["rev-parse", "--short=10", "HEAD"])
        .current_dir(repo)
        .output()
        .map_err(|error| {
            CliError::from(CliErrorKind::command_failed(format!(
                "git rev-parse: {error}"
            )))
        })?;

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
        assert_eq!(env.get("BUILD_INFO_VERSION").unwrap(), "1.2.3");
    }
}
