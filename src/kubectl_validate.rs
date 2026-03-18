use std::path::{Path, PathBuf};
use std::{env, fs};

use serde::{Deserialize, Serialize};

use crate::core_defs::{dirs_home, harness_data_root};
use crate::errors::{CliError, CliErrorKind, cow, io_for};

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
        CliErrorKind::workflow_parse(cow!("failed to parse {}: {e}", path.display())).into()
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
mod tests {
    use super::*;

    #[test]
    fn state_path_ends_with_expected_segments() {
        let path = kubectl_validate_state_path();
        let path_str = path.to_string_lossy();
        assert!(path_str.ends_with("tooling/kubectl-validate.json"));
    }

    #[test]
    fn decision_serializes_to_snake_case() {
        let json = serde_json::to_string(&KubectlValidateDecision::Installed).unwrap();
        assert_eq!(json, r#""installed""#);
        let json = serde_json::to_string(&KubectlValidateDecision::Declined).unwrap();
        assert_eq!(json, r#""declined""#);
    }

    #[test]
    fn decision_roundtrips() {
        for decision in [
            KubectlValidateDecision::Installed,
            KubectlValidateDecision::Declined,
        ] {
            let json = serde_json::to_string(&decision).unwrap();
            let parsed: KubectlValidateDecision = serde_json::from_str(&json).unwrap();
            assert_eq!(parsed, decision);
        }
    }

    #[test]
    fn state_serializes_without_binary_path_when_none() {
        let state = KubectlValidateState {
            schema_version: 1,
            decision: KubectlValidateDecision::Declined,
            decided_at: "2026-01-01T00:00:00Z".to_string(),
            binary_path: None,
        };
        let json = serde_json::to_string(&state).unwrap();
        assert!(!json.contains("binary_path"));
    }

    #[test]
    fn state_serializes_with_binary_path_when_present() {
        let state = KubectlValidateState {
            schema_version: 1,
            decision: KubectlValidateDecision::Installed,
            decided_at: "2026-01-01T00:00:00Z".to_string(),
            binary_path: Some("/usr/local/bin/kubectl-validate".to_string()),
        };
        let json = serde_json::to_string(&state).unwrap();
        assert!(json.contains("binary_path"));
        assert!(json.contains("/usr/local/bin/kubectl-validate"));
    }

    #[test]
    fn state_roundtrips_json() {
        let state = KubectlValidateState {
            schema_version: 1,
            decision: KubectlValidateDecision::Installed,
            decided_at: "2026-01-01T00:00:00Z".to_string(),
            binary_path: Some("/bin/kv".to_string()),
        };
        let json = serde_json::to_string(&state).unwrap();
        let parsed: KubectlValidateState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, state);
    }

    #[test]
    fn state_deserializes_without_optional_binary_path() {
        let json =
            r#"{"schema_version":1,"decision":"declined","decided_at":"2026-01-01T00:00:00Z"}"#;
        let state: KubectlValidateState = serde_json::from_str(json).unwrap();
        assert!(state.binary_path.is_none());
        assert_eq!(state.decision, KubectlValidateDecision::Declined);
    }

    #[test]
    fn read_state_returns_none_when_file_missing() {
        // Point harness_data_root to a temp dir via XDG_DATA_HOME
        let dir = tempfile::tempdir().unwrap();
        let result = temp_env::with_var("XDG_DATA_HOME", Some(dir.path()), || {
            read_kubectl_validate_state().unwrap()
        });
        assert!(result.is_none());
    }

    #[test]
    fn read_state_returns_parsed_when_file_exists() {
        let dir = tempfile::tempdir().unwrap();
        let tooling = dir.path().join("kuma").join("tooling");
        fs::create_dir_all(&tooling).unwrap();
        let state_file = tooling.join("kubectl-validate.json");
        fs::write(
            &state_file,
            r#"{"schema_version":1,"decision":"installed","decided_at":"2026-01-01T00:00:00Z","binary_path":"/bin/kv"}"#,
        )
        .unwrap();

        let result = temp_env::with_var("XDG_DATA_HOME", Some(dir.path()), || {
            read_kubectl_validate_state().unwrap()
        });

        let state = result.unwrap();
        assert_eq!(state.decision, KubectlValidateDecision::Installed);
        assert_eq!(state.binary_path.as_deref(), Some("/bin/kv"));
    }

    #[test]
    fn resolve_binary_returns_none_when_nothing_available() {
        // With a fake HOME and no HARNESS_KUBECTL_VALIDATE_BIN
        let dir = tempfile::tempdir().unwrap();
        let result = temp_env::with_vars(
            [
                ("HOME", Some(dir.path().to_str().unwrap())),
                ("HARNESS_KUBECTL_VALIDATE_BIN", None::<&str>),
                (
                    "XDG_DATA_HOME",
                    Some(dir.path().join("xdg").to_str().unwrap()),
                ),
                ("PATH", Some(dir.path().join("empty-bin").to_str().unwrap())),
            ],
            resolve_kubectl_validate_binary,
        );
        assert!(result.is_none());
    }

    #[test]
    fn resolve_binary_uses_env_override() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("kubectl-validate");
        fs::write(&bin, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();

        let result = temp_env::with_var("HARNESS_KUBECTL_VALIDATE_BIN", Some(&bin), || {
            resolve_kubectl_validate_binary()
        });

        assert_eq!(result, Some(bin));
    }

    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn is_executable_returns_false_for_nonexistent() {
        assert!(!is_executable(&PathBuf::from("/nonexistent/binary")));
    }

    #[test]
    fn is_executable_returns_true_for_executable_file() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("test-bin");
        fs::write(&bin, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(is_executable(&bin));
    }

    #[test]
    fn is_executable_returns_false_for_non_executable_file() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("test-bin");
        fs::write(&bin, "data").unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!is_executable(&bin));
    }
}
