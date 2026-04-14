use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::PoisonError;

use harness::run::{KumactlArgs, KumactlCommand};
use harness::setup::ClusterArgs;

use super::super::helpers::*;

fn k3d_cluster_args(
    mode: &str,
    cluster_name: &str,
    extra_cluster_names: Vec<&str>,
    repo_root: &Path,
    run_dir: Option<&Path>,
) -> ClusterArgs {
    ClusterArgs {
        mode: mode.into(),
        cluster_name: cluster_name.into(),
        extra_cluster_names: extra_cluster_names
            .into_iter()
            .map(str::to_string)
            .collect(),
        repo_root: Some(repo_root.to_str().unwrap().into()),
        run_dir: run_dir.map(|path| path.to_str().unwrap().into()),
        platform: "kubernetes".into(),
        provider: None,
        remote: vec![],
        helm_setting: vec![],
        restart_namespace: vec![],
        store: "memory".into(),
        image: None,
        no_build: false,
        no_load: false,
        push_prefix: None,
        push_tag: None,
        namespace: "kuma-system".into(),
        release_name: "kuma".into(),
    }
}

// ============================================================================
// Cluster orchestration tests (require external cluster tools)
// ============================================================================

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
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
    tc.add_make()
        .add_k3d_cluster_list(&[])
        .add_docker()
        .add_kubectl("30685");
    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
            ("HARNESS_CONTAINER_RUNTIME", Some("docker-cli")),
        ],
        || {
            let result = cluster_cmd(k3d_cluster_args(
                "global-zone-up",
                "kuma-global",
                vec!["kuma-zone", "zone-1"],
                &repo,
                None,
            ))
            .execute();
            assert!(result.is_ok(), "global-zone-up failed: {result:?}");
            assert_eq!(result.unwrap(), 0);

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
#[ignore = "slow: spawns fake toolchain processes"]
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
            let result = cluster_cmd(k3d_cluster_args(
                "single-up",
                "kuma-test",
                vec![],
                &repo,
                None,
            ))
            .execute();
            assert!(result.is_ok(), "single-up failed: {result:?}");
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn single_up_dynamic_metallb_bootstrap() {
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
            let result = cluster_cmd(k3d_cluster_args(
                "single-up",
                "kuma-metallb",
                vec![],
                &repo,
                None,
            ))
            .execute();
            assert!(
                result.is_ok(),
                "single-up dynamic metallb failed: {result:?}"
            );
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
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

    let run_dir = init_run(tmp.path(), "run-ctx", "single-zone");
    let deploy = serde_json::json!({
        "mode": "single-up",
        "mode_args": ["kuma-ctx"],
        "members": [
            {"name": "kuma-ctx", "role": "primary", "kubeconfig": "/tmp/k3d-kuma-ctx.yaml"}
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
            let result = cluster_cmd(k3d_cluster_args(
                "single-up",
                "kuma-ctx",
                vec![],
                &repo,
                Some(&run_dir),
            ))
            .execute();
            assert!(result.is_ok(), "single-up with context failed: {result:?}");
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
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
            let up_result = cluster_cmd(k3d_cluster_args(
                "single-up",
                "kuma-updown",
                vec![],
                &repo,
                None,
            ))
            .execute();
            assert!(up_result.is_ok(), "single-up failed: {up_result:?}");
            assert_eq!(up_result.unwrap(), 0);
        },
    );

    let mut tc2 = FakeToolchain::new();
    tc2.add_make().add_k3d_cluster_list(&["kuma-updown"]);
    let new_path2 = tc2.path_with_prepend(&orig_path);
    temp_env::with_vars(
        [
            ("PATH", Some(new_path2.as_str())),
            ("HOME", Some(tmp.path().to_str().unwrap())),
        ],
        || {
            let down_result = cluster_cmd(k3d_cluster_args(
                "single-down",
                "kuma-updown",
                vec![],
                &repo,
                None,
            ))
            .execute();
            assert!(down_result.is_ok(), "single-down failed: {down_result:?}");
            assert_eq!(down_result.unwrap(), 0);

            let make_calls = tc2.invocations("make");
            assert!(
                make_calls.iter().any(|c| c.contains("k3d/cluster/stop")),
                "expected make k3d/cluster/stop invocation, got: {make_calls:?}"
            );
        },
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
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
            let result = cluster_cmd(k3d_cluster_args(
                "single-up",
                "kuma-saved",
                vec![],
                &repo,
                None,
            ))
            .execute();
            assert!(
                result.is_ok(),
                "cluster with saved repo root failed: {result:?}"
            );
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn kumactl_find_repo_root() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();

    let bin_dir = repo.join("bin");
    fs::create_dir_all(&bin_dir).unwrap();
    fs::write(bin_dir.join("kumactl"), "#!/bin/sh\necho kumactl\n").unwrap();
    fs::set_permissions(bin_dir.join("kumactl"), fs::Permissions::from_mode(0o755)).unwrap();

    let cmd = KumactlCommand::Find {
        repo_root: Some(repo.to_str().unwrap().to_string()),
    };
    let result = kumactl_cmd(KumactlArgs { cmd }).execute();
    assert!(result.is_ok(), "kumactl find failed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}
