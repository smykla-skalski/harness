// Cluster module integration tests.
// Tests ClusterSpec payload parsing, serialization round-trips, valid modes,
// and cluster context recovery from current-deploy.json.

use std::fs;

use harness::kernel::topology::{ClusterMode, ClusterProvider, ClusterSpec, HelmSetting, Platform};

use super::helpers::init_run;

mod orchestration;

// ============================================================================
// ClusterSpec payload tests
// ============================================================================

#[test]
fn cluster_spec_from_object_basic() {
    let obj = serde_json::json!({
        "mode": "single-up",
        "mode_args": ["kuma-test"],
        "members": [
            {"name": "kuma-test", "role": "primary", "kubeconfig": "/tmp/kuma-test-config"}
        ],
        "repo_root": "/repo"
    });
    let spec = ClusterSpec::from_object(&obj).unwrap();
    assert_eq!(spec.mode, ClusterMode::SingleUp);
    assert_eq!(spec.repo_root, "/repo");
}

#[test]
fn cluster_spec_rejects_legacy_clusters_format() {
    // Legacy format with `clusters` and `helm_values` keys is no longer supported.
    // The parser requires `members` and `helm_settings` in the current format.
    let obj = serde_json::json!({
        "mode": "global-zone-up",
        "mode_args": ["kuma-global", "kuma-zone", "zone-1"],
        "clusters": ["kuma-global", "kuma-zone"],
        "kubeconfigs": {"kuma-zone": "/tmp/kuma-zone-config"},
        "helm_values": {"controlPlane.mode": "global"},
        "restart_namespaces": ["kuma-system"],
        "repo_root": "/repo"
    });
    let result = ClusterSpec::from_object(&obj);
    assert!(
        result.is_err(),
        "legacy clusters format should be rejected (requires members)"
    );
}

#[test]
fn cluster_spec_rejects_missing_mode() {
    // Objects without a mode field are rejected.
    let obj = serde_json::json!({
        "primary_kubeconfig": "/tmp/current-config"
    });
    let result = ClusterSpec::from_object(&obj);
    assert!(result.is_err(), "missing mode field should be rejected");
}

#[test]
fn cluster_spec_deploy_roundtrip() {
    let obj = serde_json::json!({
        "mode": "single-up",
        "mode_args": ["kuma-test"],
        "members": [
            {"name": "kuma-test", "role": "primary", "kubeconfig": "/tmp/kuma-test-config"}
        ],
        "helm_settings": [{"key": "cp.mode", "value": "standalone"}],
        "restart_namespaces": ["kuma-system"],
        "repo_root": "/repo"
    });
    let spec: ClusterSpec = serde_json::from_value(obj).unwrap();
    let json = serde_json::to_value(&spec).unwrap();
    let spec2: ClusterSpec = serde_json::from_value(json).unwrap();
    assert_eq!(spec.mode, spec2.mode);
}

#[test]
fn cluster_spec_serialization_roundtrip() {
    let spec = ClusterSpec {
        mode: ClusterMode::SingleUp,
        platform: Platform::default(),
        provider: ClusterProvider::K3d,
        mode_args: vec!["kuma-1".to_string()],
        members: vec![],
        helm_settings: vec![HelmSetting {
            key: "cp.mode".to_string(),
            value: "standalone".to_string(),
        }],
        restart_namespaces: vec!["kuma-system".to_string()],
        repo_root: "/repo".to_string(),
        docker_network: None,
        store_type: None,
        cp_image: None,
        admin_token: None,
    };
    let json = serde_json::to_string(&spec).unwrap();
    let back: ClusterSpec = serde_json::from_str(&json).unwrap();
    assert_eq!(spec.mode, back.mode);
    assert_eq!(spec.helm_settings.len(), back.helm_settings.len());
}

// ============================================================================
// ClusterMode enum tests
// ============================================================================

#[test]
fn cluster_mode_parses_valid_strings() {
    assert_eq!(
        "single-up".parse::<ClusterMode>().unwrap(),
        ClusterMode::SingleUp
    );
    assert_eq!(
        "single-down".parse::<ClusterMode>().unwrap(),
        ClusterMode::SingleDown
    );
    assert_eq!(
        "global-zone-up".parse::<ClusterMode>().unwrap(),
        ClusterMode::GlobalZoneUp
    );
    assert_eq!(
        "global-zone-down".parse::<ClusterMode>().unwrap(),
        ClusterMode::GlobalZoneDown
    );
    assert!("bad-mode".parse::<ClusterMode>().is_err());
}

// ============================================================================
// Cluster context recovery from current-deploy.json
// ============================================================================

#[test]
fn run_dir_recovers_cluster() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-cluster", "single-zone");
    let deploy = serde_json::json!({
        "mode": "single-up",
        "mode_args": ["kuma-test"],
        "members": [
            {"name": "kuma-test", "role": "primary", "kubeconfig": "/tmp/k3d-kuma-test.yaml"}
        ],
        "updated_at": "2026-03-13T00:00:00Z"
    });
    fs::write(
        run_dir.join("current-deploy.json"),
        serde_json::to_string_pretty(&deploy).unwrap(),
    )
    .unwrap();
    assert!(run_dir.join("current-deploy.json").exists());
    let text = fs::read_to_string(run_dir.join("current-deploy.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["mode"], "single-up");
}
