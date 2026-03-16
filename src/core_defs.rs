use std::collections::HashMap;
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest, Sha256};

use crate::errors::{CliError, CliErrorKind, cow};

/// Prefix used for harness-owned resources (containers, networks, temp dirs).
pub const HARNESS_PREFIX: &str = "harness-";

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

/// Read an env var, returning `None` if empty, an unexpanded shell variable,
/// or a known sentinel value like "UNSET".
fn context_scope_value(name: &str) -> Option<String> {
    let value = env::var(name).unwrap_or_default();
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("${") && trimmed.ends_with('}') {
        return None;
    }
    if trimmed.eq_ignore_ascii_case("unset") {
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
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn session_scope_key() -> Result<String, CliError> {
    if let Some(session_id) = context_scope_value("CLAUDE_SESSION_ID") {
        let scope = format!("session:{session_id}");
        return Ok(format!("session-{}", scope_digest(&scope)));
    }
    if let Some(project_dir) = context_scope_value("CLAUDE_PROJECT_DIR") {
        let resolved = PathBuf::from(project_dir).canonicalize()?;
        let scope = format!("project:{}", resolved.display());
        return Ok(format!("project-{}", scope_digest(&scope)));
    }
    let cwd = env::current_dir()?;
    let resolved = cwd.canonicalize().unwrap_or(cwd);
    let scope = format!("cwd:{}", resolved.display());
    Ok(format!("cwd-{}", scope_digest(&scope)))
}

/// Session context directory.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn session_context_dir() -> Result<PathBuf, CliError> {
    Ok(harness_data_root()
        .join("contexts")
        .join(session_scope_key()?))
}

/// Path to the current run context JSON file.
///
/// # Errors
/// Returns `CliError` if the current directory cannot be determined.
pub fn current_run_context_path() -> Result<PathBuf, CliError> {
    Ok(session_context_dir()?.join("current-run.json"))
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
///
/// When the merged env contains `REPO_ROOT`, the build artifacts directory
/// for the host platform is prepended to `PATH` so that locally-built
/// binaries (like `kumactl`) are found before system-installed ones.
#[must_use]
pub(crate) fn merge_env(extra: Option<&HashMap<String, String>>) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = env::vars().collect();
    if let Some(extra) = extra {
        env.extend(extra.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    prepend_build_artifacts_path(&mut env);
    env
}

/// Host platform as `(os_name, arch)` - e.g. `("darwin", "arm64")`.
#[must_use]
pub fn host_platform() -> (&'static str, &'static str) {
    let os_name = if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    };
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };
    (os_name, arch)
}

/// If `REPO_ROOT` is set, prepend `{repo_root}/build/artifacts-{os}-{arch}/kumactl`
/// to `PATH` so locally-built binaries are preferred over system ones.
fn prepend_build_artifacts_path(env: &mut HashMap<String, String>) {
    let Some(repo_root) = env.get("REPO_ROOT") else {
        return;
    };
    if repo_root.is_empty() {
        return;
    }
    let (os_name, arch) = host_platform();
    let artifacts_dir = Path::new(repo_root)
        .join("build")
        .join(format!("artifacts-{os_name}-{arch}"))
        .join("kumactl");
    if !artifacts_dir.is_dir() {
        return;
    }
    let artifacts_str = artifacts_dir.to_string_lossy();
    let current_path = env.get("PATH").cloned().unwrap_or_default();
    env.insert("PATH".into(), format!("{artifacts_str}:{current_path}"));
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

pub fn dirs_home() -> PathBuf {
    env::var("HOME").map_or_else(
        |_| env::temp_dir().join(format!("{HARNESS_PREFIX}{}", uzers::get_current_uid())),
        PathBuf::from,
    )
}

/// Shorten an absolute path for human-readable terminal output.
///
/// Paths under the harness data root become `~kuma/<rest>`.
/// Other paths under `$HOME` get the home prefix replaced with `~`.
/// Everything else is returned unchanged.
#[must_use]
pub fn shorten_path(path: &Path) -> String {
    let hdr = harness_data_root();
    if let Ok(rel) = path.strip_prefix(&hdr) {
        return format!("~kuma/{}", rel.display());
    }
    let home = dirs_home();
    if let Ok(rel) = path.strip_prefix(&home) {
        return format!("~/{}", rel.display());
    }
    path.display().to_string()
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
        let err = CliErrorKind::command_failed("msg").with_details("more");
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
        temp_env::with_vars([("CLAUDE_SESSION_ID", Some("combined-scope-test"))], || {
            // session_scope_key uses session prefix
            let key = session_scope_key().unwrap();
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
            let key2 = session_scope_key().unwrap();
            assert_eq!(key, key2);

            // current_run_context_path is under session context dir
            let path = current_run_context_path().unwrap();
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
        });
    }

    #[test]
    fn session_scope_ignores_unset_sentinel() {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("UNSET")),
                ("CLAUDE_PROJECT_DIR", None::<&str>),
            ],
            || {
                let key = session_scope_key().unwrap();
                assert!(
                    !key.starts_with("session-"),
                    "UNSET should not produce a session scope: {key}"
                );
            },
        );
    }

    #[test]
    fn merge_env_prepends_build_artifacts_to_path() {
        let tmp = tempfile::tempdir().unwrap();
        let os_name = if cfg!(target_os = "macos") {
            "darwin"
        } else {
            "linux"
        };
        let arch = if cfg!(target_arch = "aarch64") {
            "arm64"
        } else {
            "amd64"
        };
        let artifacts_dir = tmp
            .path()
            .join("build")
            .join(format!("artifacts-{os_name}-{arch}"))
            .join("kumactl");
        std::fs::create_dir_all(&artifacts_dir).unwrap();

        let mut extra = HashMap::new();
        extra.insert(
            "REPO_ROOT".into(),
            tmp.path().to_string_lossy().into_owned(),
        );
        let merged = merge_env(Some(&extra));
        let path_val = merged.get("PATH").unwrap();
        let expected_prefix = artifacts_dir.to_string_lossy();
        assert!(
            path_val.starts_with(expected_prefix.as_ref()),
            "PATH should start with artifacts dir, got: {path_val}"
        );
    }

    #[test]
    fn merge_env_skips_artifacts_when_dir_missing() {
        let tmp = tempfile::tempdir().unwrap();
        // No build directory created - artifacts dir does not exist
        let mut extra = HashMap::new();
        extra.insert(
            "REPO_ROOT".into(),
            tmp.path().to_string_lossy().into_owned(),
        );
        let original_path = env::var("PATH").unwrap_or_default();
        let merged = merge_env(Some(&extra));
        let path_val = merged.get("PATH").unwrap();
        assert_eq!(
            path_val, &original_path,
            "PATH should be unchanged when artifacts dir does not exist"
        );
    }

    #[test]
    fn merge_env_no_repo_root_leaves_path_unchanged() {
        let original_path = env::var("PATH").unwrap_or_default();
        let merged = merge_env(None);
        let path_val = merged.get("PATH").unwrap();
        assert_eq!(path_val, &original_path);
    }

    #[test]
    fn prepend_build_artifacts_path_ignores_empty_repo_root() {
        let mut env_map = HashMap::new();
        env_map.insert("REPO_ROOT".into(), String::new());
        env_map.insert("PATH".into(), "/usr/bin".into());
        prepend_build_artifacts_path(&mut env_map);
        assert_eq!(env_map.get("PATH").unwrap(), "/usr/bin");
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
