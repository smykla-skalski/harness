use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;

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

fn parse_version_script_output(stdout: &[u8]) -> Option<String> {
    String::from_utf8_lossy(stdout)
        .split_whitespace()
        .next()
        .map(str::to_owned)
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
        && let Some(version) = parse_version_script_output(&output.stdout)
    {
        return Ok(BuildInfo { version });
    }

    let repository = GitRepository::discover(repo)
        .map_err(|error| CliError::from(CliErrorKind::command_failed(error.to_string())))?;
    if repository
        .is_dirty()
        .map_err(|error| CliError::from(CliErrorKind::command_failed(error.to_string())))?
    {
        return Ok(BuildInfo {
            version: "0.0.0-preview.vlocal-build".into(),
        });
    }

    let short_sha = repository
        .short_head_sha(10)
        .map_err(|error| CliError::from(CliErrorKind::command_failed(error.to_string())))?
        .ok_or_else(|| CliError::from(CliErrorKind::command_failed("repository has no HEAD")))?;

    Ok(BuildInfo {
        version: format!("0.0.0-preview.v{short_sha}"),
    })
}

#[cfg(test)]
mod tests;
