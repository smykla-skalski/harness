use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

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
    let json = r#"{"schema_version":1,"decision":"declined","decided_at":"2026-01-01T00:00:00Z"}"#;
    let state: KubectlValidateState = serde_json::from_str(json).unwrap();
    assert!(state.binary_path.is_none());
    assert_eq!(state.decision, KubectlValidateDecision::Declined);
}

#[test]
fn read_state_returns_none_when_file_missing() {
    let dir = tempfile::tempdir().unwrap();
    let result = temp_env::with_var("XDG_DATA_HOME", Some(dir.path()), || {
        read_kubectl_validate_state().unwrap()
    });
    assert!(result.is_none());
}

#[test]
fn read_state_returns_parsed_when_file_exists() {
    let dir = tempfile::tempdir().unwrap();
    let tooling = dir.path().join("harness").join("tooling");
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
