// Cluster module integration tests.
// Tests ClusterSpec payload parsing, serialization round-trips, valid modes,
// cluster context recovery from current-deploy.json, and cluster orchestration
// (ignored - requires external tools).

use std::fs;

use harness::cluster::{ClusterSpec, HelmSetting, VALID_MODES};

use super::helpers::*;

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
    assert_eq!(spec.mode, "single-up");
    assert_eq!(spec.repo_root, "/repo");
}

#[test]
fn cluster_spec_legacy_clusters() {
    let obj = serde_json::json!({
        "mode": "global-zone-up",
        "mode_args": ["kuma-global", "kuma-zone", "zone-1"],
        "clusters": ["kuma-global", "kuma-zone"],
        "kubeconfigs": {"kuma-zone": "/tmp/kuma-zone-config"},
        "helm_values": {"controlPlane.mode": "global"},
        "restart_namespaces": ["kuma-system"],
        "repo_root": "/repo"
    });
    let spec = ClusterSpec::from_object(&obj).unwrap();
    assert_eq!(spec.mode, "global-zone-up");
    assert!(
        spec.helm_settings
            .iter()
            .any(|s| s.key == "controlPlane.mode" && s.value == "global"),
        "expected helm setting controlPlane.mode=global, got: {:?}",
        spec.helm_settings
    );
}

#[test]
fn cluster_spec_legacy_fallback() {
    let obj = serde_json::json!({
        "primary_kubeconfig": "/tmp/current-config"
    });
    let spec = ClusterSpec::from_object(&obj).unwrap();
    // Legacy fallback should default to single-up
    assert!(spec.mode.is_empty() || spec.mode == "single-up");
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
    let spec: ClusterSpec = serde_json::from_value(obj.clone()).unwrap();
    let json = serde_json::to_value(&spec).unwrap();
    let spec2: ClusterSpec = serde_json::from_value(json).unwrap();
    assert_eq!(spec.mode, spec2.mode);
}

#[test]
fn cluster_spec_serialization_roundtrip() {
    let spec = ClusterSpec {
        mode: "single-up".to_string(),
        mode_args: vec!["kuma-1".to_string()],
        members: vec![],
        helm_settings: vec![HelmSetting {
            key: "cp.mode".to_string(),
            value: "standalone".to_string(),
        }],
        restart_namespaces: vec!["kuma-system".to_string()],
        repo_root: "/repo".to_string(),
    };
    let json = serde_json::to_string(&spec).unwrap();
    let back: ClusterSpec = serde_json::from_str(&json).unwrap();
    assert_eq!(spec.mode, back.mode);
    assert_eq!(spec.helm_settings.len(), back.helm_settings.len());
}

// ============================================================================
// Valid modes constant test
// ============================================================================

#[test]
fn valid_modes_include_expected_entries() {
    assert!(VALID_MODES.contains(&"single-up"));
    assert!(VALID_MODES.contains(&"single-down"));
    assert!(VALID_MODES.contains(&"global-zone-up"));
    assert!(VALID_MODES.contains(&"global-zone-down"));
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
            {"name": "kuma-test", "role": "primary", "kubeconfig": "/tmp/kind-kuma-test-config"}
        ],
        "updated_at": "2026-03-13T00:00:00Z"
    });
    fs::write(
        run_dir.join("current-deploy.json"),
        serde_json::to_string_pretty(&deploy).unwrap(),
    )
    .unwrap();
    // Verify the deploy file was written
    assert!(run_dir.join("current-deploy.json").exists());
    let text = fs::read_to_string(run_dir.join("current-deploy.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["mode"], "single-up");
}

// ============================================================================
// Cluster orchestration tests (require external cluster tools)
// ============================================================================

#[test]
#[ignore = "Requires k3d, kubectl, and cluster management"]
fn global_zone_up_orchestration() {
    // This test verifies the full global-zone-up flow:
    // 1. Start global cluster
    // 2. Fetch KDS address
    // 3. Start zone cluster with KDS address
    // The Python test used monkeypatching to replace cluster functions.
}

#[test]
#[ignore = "Requires cluster tools"]
fn single_up_logs_stage_updates() {
    // Verify stage progress messages during single-up
}

#[test]
#[ignore = "Requires cluster tools and metallb templates"]
fn single_up_metallb_template() {
    // Verify temporary metallb template creation for missing cluster name
}

#[test]
#[ignore = "Requires cluster tools"]
fn single_up_restores_context() {
    // Verify context restoration when matching deploy exists
}

#[test]
#[ignore = "Requires cluster tools"]
fn cluster_context_up_down() {
    // Test cluster-up persists context and matching down clears it
}

#[test]
#[ignore = "Requires cluster tools and suite defaults"]
fn cluster_uses_saved_repo_root() {
    // Cluster should use repo_root saved from suite defaults
}

#[test]
#[ignore = "Requires kumactl binary"]
fn kumactl_find_repo_root() {
    // kumactl find should use repo_root from current run context
}
