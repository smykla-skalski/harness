use std::env;
use std::fs;

use harness::run::{CaptureArgs, RecordArgs, RunDirArgs};
use harness::setup::GatewayArgs;
use harness_testkit::FakeToolchain;

use super::super::super::helpers::*;
use super::{kumactl_binary_dir, txt_artifact_paths};

pub(super) fn check_run_records_kubectl_with_active_run_kubeconfig() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-kc", "single-zone");
    let mut tc = FakeToolchain::new();
    tc.add_kubectl("pod-list-output");

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = record_cmd(RecordArgs {
            repo_root: None,
            phase: Some("verify".into()),
            label: Some("check".into()),
            gid: None,
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "pods".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok(), "record kubectl should succeed: {result:?}");
    });

    let artifacts = txt_artifact_paths(&run_dir.join("commands"));
    assert!(!artifacts.is_empty(), "artifact should be created");
}

pub(super) fn check_record_rewrites_kubectl_to_tracked_kubeconfig() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-kc-rw", "single-zone");
    let mut tc = FakeToolchain::new();
    tc.add_kubectl("rewritten-output");

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = record_cmd(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
            gid: None,
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "pods".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok());
    });

    let artifacts = txt_artifact_paths(&run_dir.join("commands"));
    assert!(!artifacts.is_empty());
}

pub(super) fn check_record_rejects_kubectl_target_override() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-kc-override", "single-zone");
    let mut tc = FakeToolchain::new();
    tc.add_kubectl("override-output");

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = record_cmd(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
            gid: None,
            cluster: None,
            command: vec![
                "kubectl".into(),
                "--kubeconfig".into(),
                "/tmp/custom.conf".into(),
                "get".into(),
                "pods".into(),
            ],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok());
    });
}

pub(super) fn check_record_rejects_kubectl_without_tracked_cluster() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-no-cluster", "single-zone");
    let mut tc = FakeToolchain::new();
    tc.add_kubectl("no-cluster-output");

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = record_cmd(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
            gid: None,
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "pods".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok());
    });
}

pub(super) fn check_record_kubectl_without_tracked_kubeconfig_fails_closed() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-no-kc", "single-zone");
    let mut tc = FakeToolchain::new();
    tc.add_kubectl("no-kc-output");

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = record_cmd(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
            gid: None,
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "namespaces".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok());
    });
}

pub(super) fn check_kumactl_build_runs_make_and_prints_binary() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_make();

    let kumactl_dir = kumactl_binary_dir(&repo_root);
    fs::create_dir_all(&kumactl_dir).unwrap();
    fs::write(kumactl_dir.join("kumactl"), "#!/bin/sh\necho kumactl").unwrap();

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let cmd = harness::run::KumactlCommand::Build {
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = kumactl_cmd(harness::run::KumactlArgs { cmd: cmd.clone() }).execute();
        assert!(result.is_ok(), "kumactl build should succeed: {result:?}");
    });
}

pub(super) fn check_bootstrap_command_runs_gateway_api_crd_install() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    fs::write(
        repo_root.join("go.mod"),
        "module example.com/repo\n\nrequire sigs.k8s.io/gateway-api v1.2.0\n",
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("customresourcedefinition.apiextensions.k8s.io/gatewayclasses found");
    tc.add_curl();

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = gateway_cmd(GatewayArgs {
            kubeconfig: None,
            repo_root: Some(repo_root.to_string_lossy().to_string()),
            check_only: true,
            uninstall: false,
        })
        .execute();
        assert!(result.is_ok(), "gateway check should succeed: {result:?}");
    });
}

pub(super) fn check_capture_uses_current_run_context() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-capture", "single-zone");
    seed_cluster_state(&run_dir, "/tmp/fake-kubeconfig");

    let mut tc = FakeToolchain::new();
    tc.add_kubectl(r#"{"items":[]}"#);

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = capture_cmd(CaptureArgs {
            kubeconfig: Some("/tmp/fake-kubeconfig".to_string()),
            label: "pod-state".to_string(),
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok(), "capture should succeed: {result:?}");
    });

    let state_dir = run_dir.join("state");
    let captures: Vec<_> = fs::read_dir(&state_dir)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().contains("pod-state"))
        .collect();
    assert!(
        !captures.is_empty(),
        "capture artifact should exist in state/"
    );
}
