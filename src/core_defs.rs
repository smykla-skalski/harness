use std::collections::HashMap;
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest, Sha256};

use crate::errors::{CliError, CliErrorKind};

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

/// Return current UTC time as ISO 8601 with Z suffix and no microseconds.
#[must_use]
pub fn utc_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// XDG data root (`XDG_DATA_HOME` or `~/.local/share`).
#[must_use]
pub fn data_root() -> PathBuf {
    if let Ok(xdg) = env::var("XDG_DATA_HOME")
        && !xdg.is_empty()
    {
        return PathBuf::from(xdg);
    }
    dirs_home().join(".local").join("share")
}

/// Harness data root: `data_root/kuma`.
#[must_use]
pub fn harness_data_root() -> PathBuf {
    data_root().join("kuma")
}

/// Suite root: `harness_data_root/suites`.
#[must_use]
pub fn suite_root() -> PathBuf {
    harness_data_root().join("suites")
}

/// Read an env var, returning `None` if empty or an unexpanded shell variable.
fn context_scope_value(name: &str) -> Option<String> {
    let value = env::var(name).unwrap_or_default();
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("${") && trimmed.ends_with('}') {
        return None;
    }
    Some(trimmed.to_string())
}

/// Compute a hex digest prefix from a scope string.
fn scope_digest(scope: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.as_bytes());
    let hash = hasher.finalize();
    hex_encode_prefix(&hash, 8)
}

/// Encode the first `n` bytes of a hash as lowercase hex (producing `2*n` chars).
fn hex_encode_prefix(bytes: &[u8], n: usize) -> String {
    bytes
        .iter()
        .take(n)
        .fold(String::with_capacity(n * 2), |mut acc, b| {
            use std::fmt::Write;
            let _ = write!(acc, "{b:02x}");
            acc
        })
}

/// Compute a context scope key from environment (session > project > cwd).
#[must_use]
pub fn session_scope_key() -> String {
    if let Some(session_id) = context_scope_value("CLAUDE_SESSION_ID") {
        let scope = format!("session:{session_id}");
        return format!("session-{}", scope_digest(&scope));
    }
    if let Some(project_dir) = context_scope_value("CLAUDE_PROJECT_DIR") {
        let resolved = PathBuf::from(project_dir)
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(""));
        let scope = format!("project:{}", resolved.display());
        return format!("project-{}", scope_digest(&scope));
    }
    let cwd = env::current_dir().unwrap_or_default();
    let resolved = cwd.canonicalize().unwrap_or(cwd);
    let scope = format!("cwd:{}", resolved.display());
    format!("cwd-{}", scope_digest(&scope))
}

/// Session context directory.
#[must_use]
pub fn session_context_dir() -> PathBuf {
    harness_data_root()
        .join("contexts")
        .join(session_scope_key())
}

/// Path to the current run context JSON file.
#[must_use]
pub fn current_run_context_path() -> PathBuf {
    session_context_dir().join("current-run.json")
}

/// Project context directory (hashed from project path).
#[must_use]
pub fn project_context_dir(project_dir: &Path) -> PathBuf {
    let resolved = project_dir
        .canonicalize()
        .unwrap_or_else(|_| project_dir.to_path_buf());
    let scope = resolved.to_string_lossy();
    let mut hasher = Sha256::new();
    hasher.update(scope.as_bytes());
    let hash = hasher.finalize();
    let digest = hex_encode_prefix(&hash, 8);
    harness_data_root()
        .join("projects")
        .join(format!("project-{digest}"))
}

/// Merge current env with extra key-value pairs.
#[must_use]
pub(crate) fn merge_env(extra: Option<&HashMap<String, String>>) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = env::vars().collect();
    if let Some(extra) = extra {
        env.extend(extra.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    env
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
        .map_err(|e| {
            CliError::from(CliErrorKind::CommandFailed {
                command: format!("git status: {e}"),
            })
        })?;

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
        .map_err(|e| {
            CliError::from(CliErrorKind::CommandFailed {
                command: format!("git rev-parse: {e}"),
            })
        })?;

    let short_sha = String::from_utf8_lossy(&sha_output.stdout)
        .trim()
        .to_string();

    Ok(BuildInfo {
        version: format!("0.0.0-preview.v{short_sha}"),
    })
}

pub fn dirs_home() -> PathBuf {
    env::var("HOME").map_or_else(
        |_| env::temp_dir().join(format!("harness-{}", unsafe { libc::getuid() })),
        PathBuf::from,
    )
}

#[cfg(test)]
mod tests {
    use crate::errors::{CliErrorKind, render_error};

    use super::*;

    #[test]
    fn utc_now_ends_with_z() {
        let now = utc_now();
        assert!(now.ends_with('Z'), "expected Z suffix, got: {now}");
        assert!(!now.contains('+'), "expected no +, got: {now}");
    }

    #[test]
    fn cli_error_has_all_fields() {
        let err = CliErrorKind::CommandFailed {
            command: "msg".into(),
        }
        .with_details("more");
        assert_eq!(err.code(), "KSRCLI004");
        assert_eq!(err.message(), "command failed: msg");
        assert_eq!(err.exit_code(), 4);
        assert_eq!(err.details(), Some("more"));
    }

    #[test]
    fn render_error_includes_hint_and_details() {
        let err = CliErrorKind::MissingRunPointer.with_details("stack");
        let rendered = render_error(&err);
        assert!(
            rendered.contains("ERROR [KSRCLI005]"),
            "missing header: {rendered}"
        );
        assert!(
            rendered.contains("Hint: Run init first."),
            "missing hint: {rendered}"
        );
        assert!(rendered.contains("stack"), "missing details: {rendered}");
    }

    #[test]
    fn build_info_env() {
        let info = BuildInfo {
            version: "1.2.3".into(),
        };
        let env = info.env();
        assert_eq!(env.len(), 1);
        assert_eq!(env.get("BUILD_INFO_VERSION").unwrap(), "1.2.3");
    }

    // All env-dependent tests are combined into one test to avoid races
    // from parallel test execution mutating the same env var.
    #[test]
    fn session_scope_and_context_path() {
        unsafe {
            harness_testkit::with_env_vars(
                &[("CLAUDE_SESSION_ID", Some("combined-scope-test"))],
                || {
                    // session_scope_key uses session prefix
                    let key = session_scope_key();
                    assert!(
                        key.starts_with("session-"),
                        "expected session- prefix: {key}"
                    );
                    assert_eq!(
                        key.len(),
                        "session-".len() + 16,
                        "digest should be 16 hex chars"
                    );

                    // deterministic: calling twice gives same result
                    let key2 = session_scope_key();
                    assert_eq!(key, key2);

                    // current_run_context_path is under session context dir
                    let path = current_run_context_path();
                    assert!(
                        path.ends_with("current-run.json"),
                        "expected current-run.json suffix: {path:?}"
                    );
                    let parent_name = path
                        .parent()
                        .and_then(|p| p.file_name())
                        .unwrap()
                        .to_string_lossy();
                    assert!(
                        parent_name.starts_with("session-"),
                        "expected session- prefix: {parent_name}"
                    );
                },
            );
        }
    }

    #[test]
    fn resolve_build_info_in_current_repo() {
        let repo = env::current_dir().unwrap();
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
