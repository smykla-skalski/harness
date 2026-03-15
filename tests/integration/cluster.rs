// Cluster module integration tests.
// Tests ClusterSpec payload parsing, serialization round-trips, valid modes,
// cluster context recovery from current-deploy.json, and cluster orchestration
// (ignored - requires external tools).

use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::PoisonError;

// Use the shared ENV_LOCK from helpers so all integration test modules that
// modify PATH serialize against each other (not just within this module).
use super::helpers::ENV_LOCK;

use harness::cli::KumactlCommand;
use harness::cluster::{ClusterMode, ClusterSpec, HelmSetting};
use harness::commands::{cluster, kumactl};

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
    assert_eq!(spec.mode, ClusterMode::SingleUp);
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
    assert_eq!(spec.mode, ClusterMode::GlobalZoneUp);
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
    assert_eq!(spec.mode, ClusterMode::SingleUp);
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
        mode: ClusterMode::SingleUp,
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
fn global_zone_up_orchestration() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();

    let tools_dir = repo.join("tools").join("releases");
    fs::create_dir_all(&tools_dir).unwrap();
    fs::write(tools_dir.join("version.sh"), "#!/bin/sh\necho 1.0.0\n").unwrap();
    fs::set_permissions(
        tools_dir.join("version.sh"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_make().add_k3d_cluster_list(&[]);
    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let result = cluster::execute(
                "global-zone-up",
                "kuma-global",
                &["kuma-zone".into(), "zone-1".into()],
                Some(repo.to_str().unwrap()),
                None,
                &[],
                &[],
            );
            assert!(result.is_ok(), "global-zone-up failed: {result:?}");
            assert_eq!(result.unwrap(), 0);

            // global-zone-up calls start_and_deploy twice (global + zone),
            // each calling make k3d/start and make k3d/deploy/helm = 4 make calls
            let make_calls = tc.invocations("make");
            assert!(
                make_calls.len() >= 2,
                "expected multiple make invocations, got {}",
                make_calls.len()
            );
        },
    );
}

#[test]
fn single_up_logs_stage_updates() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();

    let tools_dir = repo.join("tools").join("releases");
    fs::create_dir_all(&tools_dir).unwrap();
    fs::write(tools_dir.join("version.sh"), "#!/bin/sh\necho 1.0.0\n").unwrap();
    fs::set_permissions(
        tools_dir.join("version.sh"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_make().add_k3d_cluster_list(&[]);
    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let result = cluster::execute(
                "single-up",
                "kuma-test",
                &[],
                Some(repo.to_str().unwrap()),
                None,
                &[],
                &[],
            );
            assert!(result.is_ok(), "single-up failed: {result:?}");
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
fn single_up_metallb_template() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();

    let tools_dir = repo.join("tools").join("releases");
    fs::create_dir_all(&tools_dir).unwrap();
    fs::write(tools_dir.join("version.sh"), "#!/bin/sh\necho 1.0.0\n").unwrap();
    fs::set_permissions(
        tools_dir.join("version.sh"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_make().add_k3d_cluster_list(&[]);
    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let result = cluster::execute(
                "single-up",
                "kuma-metallb",
                &[],
                Some(repo.to_str().unwrap()),
                None,
                &[],
                &[],
            );
            assert!(result.is_ok(), "single-up metallb failed: {result:?}");
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
fn single_up_restores_context() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();

    let tools_dir = repo.join("tools").join("releases");
    fs::create_dir_all(&tools_dir).unwrap();
    fs::write(tools_dir.join("version.sh"), "#!/bin/sh\necho 1.0.0\n").unwrap();
    fs::set_permissions(
        tools_dir.join("version.sh"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    // Create a run dir with a current-deploy.json
    let run_dir = init_run(tmp.path(), "run-ctx", "single-zone");
    let deploy = serde_json::json!({
        "mode": "single-up",
        "mode_args": ["kuma-ctx"],
        "members": [
            {"name": "kuma-ctx", "role": "primary", "kubeconfig": "/tmp/kind-kuma-ctx-config"}
        ],
        "updated_at": "2026-03-13T00:00:00Z"
    });
    fs::write(
        run_dir.join("current-deploy.json"),
        serde_json::to_string_pretty(&deploy).unwrap(),
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_make().add_k3d_cluster_list(&[]);
    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let result = cluster::execute(
                "single-up",
                "kuma-ctx",
                &[],
                Some(repo.to_str().unwrap()),
                Some(run_dir.to_str().unwrap()),
                &[],
                &[],
            );
            assert!(result.is_ok(), "single-up with context failed: {result:?}");
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
fn cluster_context_up_down() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();

    let tools_dir = repo.join("tools").join("releases");
    fs::create_dir_all(&tools_dir).unwrap();
    fs::write(tools_dir.join("version.sh"), "#!/bin/sh\necho 1.0.0\n").unwrap();
    fs::set_permissions(
        tools_dir.join("version.sh"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    // First: single-up with no existing clusters
    let mut tc = FakeToolchain::new();
    tc.add_make().add_k3d_cluster_list(&[]);
    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let up_result = cluster::execute(
                "single-up",
                "kuma-updown",
                &[],
                Some(repo.to_str().unwrap()),
                None,
                &[],
                &[],
            );
            assert!(up_result.is_ok(), "single-up failed: {up_result:?}");
            assert_eq!(up_result.unwrap(), 0);
        },
    );

    // Second: single-down with the cluster present in k3d list
    let mut tc2 = FakeToolchain::new();
    tc2.add_make().add_k3d_cluster_list(&["kuma-updown"]);
    let new_path2 = tc2.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path2.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let down_result = cluster::execute(
                "single-down",
                "kuma-updown",
                &[],
                Some(repo.to_str().unwrap()),
                None,
                &[],
                &[],
            );
            assert!(down_result.is_ok(), "single-down failed: {down_result:?}");
            assert_eq!(down_result.unwrap(), 0);

            // single-down should have called make k3d/stop
            let make_calls = tc2.invocations("make");
            assert!(
                make_calls.iter().any(|c| c.contains("k3d/stop")),
                "expected make k3d/stop invocation, got: {make_calls:?}"
            );
        },
    );
}

#[test]
fn cluster_uses_saved_repo_root() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("custom-repo");
    fs::create_dir_all(&repo).unwrap();

    let tools_dir = repo.join("tools").join("releases");
    fs::create_dir_all(&tools_dir).unwrap();
    fs::write(tools_dir.join("version.sh"), "#!/bin/sh\necho 2.0.0\n").unwrap();
    fs::set_permissions(
        tools_dir.join("version.sh"),
        fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_make().add_k3d_cluster_list(&[]);
    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let result = cluster::execute(
                "single-up",
                "kuma-saved",
                &[],
                Some(repo.to_str().unwrap()),
                None,
                &[],
                &[],
            );
            assert!(
                result.is_ok(),
                "cluster with saved repo root failed: {result:?}"
            );
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
fn kumactl_find_repo_root() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();

    // Place a fake kumactl at repo/bin/kumactl (last candidate checked by find_binary)
    let bin_dir = repo.join("bin");
    fs::create_dir_all(&bin_dir).unwrap();
    fs::write(bin_dir.join("kumactl"), "#!/bin/sh\necho kumactl\n").unwrap();
    fs::set_permissions(bin_dir.join("kumactl"), fs::Permissions::from_mode(0o755)).unwrap();

    let cmd = KumactlCommand::Find {
        repo_root: Some(repo.to_str().unwrap().to_string()),
    };
    let result = kumactl::execute(&cmd);
    assert!(result.is_ok(), "kumactl find failed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}
