use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use super::universal::{
    KUMA_CP_IMAGE_FILTERS, load_persisted_cluster_spec, resolve_cp_image, resolve_effective_store,
};
use super::{RemoteClusterTarget, parse_remote_target};

fn scope_key_for_session(session_id: &str) -> String {
    use sha2::{Digest, Sha256};
    let scope = format!("session:{session_id}");
    let mut hasher = Sha256::new();
    hasher.update(scope.as_bytes());
    let hash = hasher.finalize();
    let digest = hash
        .iter()
        .take(8)
        .fold(String::with_capacity(16), |mut acc, byte| {
            let _ = write!(acc, "{byte:02x}");
            acc
        });
    format!("session-{digest}")
}

fn write_context_file(xdg_dir: &Path, session_id: &str, content: &str) {
    let scope = scope_key_for_session(session_id);
    let ctx_dir = xdg_dir.join("harness").join("contexts").join(scope);
    fs::create_dir_all(&ctx_dir).unwrap();
    fs::write(ctx_dir.join("current-run.json"), content).unwrap();
}

#[test]
fn effective_store_uses_cli_arg_for_up() {
    let tmp = tempfile::tempdir().unwrap();
    let result = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("eff-store-up")),
        ],
        || resolve_effective_store(true, "postgres"),
    );
    assert_eq!(result, "postgres");
}

#[test]
fn effective_store_uses_persisted_for_down() {
    let tmp = tempfile::tempdir().unwrap();
    let session_id = "eff-store-down";
    let record = serde_json::json!({
        "layout": { "run_root": "/tmp/runs", "run_id": "r1" },
        "cluster": {
            "mode": "single-up",
            "platform": "universal",
            "mode_args": ["cp"],
            "members": [{"name": "cp", "role": "cp", "kubeconfig": ""}],
            "helm_settings": [],
            "restart_namespaces": [],
            "repo_root": "/r",
            "store_type": "postgres"
        }
    });
    write_context_file(
        tmp.path(),
        session_id,
        &serde_json::to_string(&record).unwrap(),
    );
    let result = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some(session_id)),
        ],
        || resolve_effective_store(false, "memory"),
    );
    assert_eq!(result, "postgres");
}

#[test]
fn effective_store_falls_back_to_cli_for_down() {
    let tmp = tempfile::tempdir().unwrap();
    let result = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("eff-store-fallback")),
        ],
        || resolve_effective_store(false, "memory"),
    );
    assert_eq!(result, "memory");
}

#[test]
fn load_persisted_spec_none_when_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let result = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("load-test-missing")),
        ],
        load_persisted_cluster_spec,
    );
    assert!(result.unwrap().is_none());
}

#[test]
fn load_persisted_spec_err_when_corrupt() {
    let tmp = tempfile::tempdir().unwrap();
    let session_id = "load-test-corrupt";
    write_context_file(tmp.path(), session_id, "not valid json {{{{");
    let result = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some(session_id)),
        ],
        load_persisted_cluster_spec,
    );
    assert!(result.is_err());
}

#[test]
fn load_persisted_spec_returns_cluster() {
    let tmp = tempfile::tempdir().unwrap();
    let session_id = "load-test-valid";
    let record = serde_json::json!({
        "layout": { "run_root": "/tmp/runs", "run_id": "r1" },
        "cluster": {
            "mode": "single-up",
            "platform": "universal",
            "mode_args": ["cp"],
            "members": [{"name": "cp", "role": "cp", "kubeconfig": ""}],
            "helm_settings": [],
            "restart_namespaces": [],
            "repo_root": "/r",
            "store_type": "postgres"
        }
    });
    write_context_file(
        tmp.path(),
        session_id,
        &serde_json::to_string(&record).unwrap(),
    );
    let result = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some(session_id)),
        ],
        load_persisted_cluster_spec,
    );
    let spec = result.unwrap().expect("should load cluster spec");
    assert_eq!(spec.store_type.as_deref(), Some("postgres"));
}

#[test]
fn kuma_cp_image_filters_include_glob_pattern() {
    assert!(KUMA_CP_IMAGE_FILTERS[0].contains('*'));
    assert_eq!(KUMA_CP_IMAGE_FILTERS[0], "reference=*kuma-cp");
}

#[test]
fn kuma_cp_image_filters_include_bare_name() {
    assert!(KUMA_CP_IMAGE_FILTERS.contains(&"reference=kuma-cp"));
}

#[test]
fn resolve_cp_image_returns_explicit_image() {
    let tmp = tempfile::tempdir().unwrap();
    let result = resolve_cp_image(tmp.path(), Some("my-registry/kuma-cp:v1.0"), false);
    assert_eq!(result.unwrap(), "my-registry/kuma-cp:v1.0");
}

#[test]
fn resolve_cp_image_returns_explicit_even_with_skip_build() {
    let tmp = tempfile::tempdir().unwrap();
    let result = resolve_cp_image(tmp.path(), Some("kumahq/kuma-cp:latest"), true);
    assert_eq!(result.unwrap(), "kumahq/kuma-cp:latest");
}

#[test]
fn parse_remote_target_accepts_context() {
    let target =
        parse_remote_target("name=kuma-1,kubeconfig=/tmp/global.yaml,context=global").unwrap();
    assert_eq!(
        target,
        RemoteClusterTarget {
            name: "kuma-1".into(),
            kubeconfig: "/tmp/global.yaml".into(),
            context: Some("global".into()),
        }
    );
}

#[test]
fn parse_remote_target_requires_name_and_kubeconfig() {
    let missing_name = parse_remote_target("kubeconfig=/tmp/global.yaml").unwrap_err();
    assert!(missing_name.contains("missing `name`"));

    let missing_kubeconfig = parse_remote_target("name=kuma-1").unwrap_err();
    assert!(missing_kubeconfig.contains("missing `kubeconfig`"));
}
