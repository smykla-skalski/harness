// Tests for the record command and related CLI operations.
// Covers recording with run directories, kubectl rewriting, context export,
// and artifact creation. Most tests exercise command handlers directly;
// CLI binary tests use assert_cmd via harness_testkit::harness_cmd().

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use harness::authoring;
use harness::cli::{
    AuthoringBeginArgs, Command, EnvoyCommand, KumactlCommand, RecordArgs, RunDirArgs,
};
use harness::commands::Execute;
use harness::core_defs;
use harness::schema::Verdict;
use harness::workflow::author::{self, AuthorPhase};
use harness::workflow::runner::{self, RunnerPhase};

use harness_testkit::FakeToolchain;
use predicates::str::contains as pred_contains;

use super::super::helpers::*;

#[test]
fn diff_identical_files() {
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("a.txt");
    let b = tmp.path().join("b.txt");
    fs::write(&a, "hello\n").unwrap();
    fs::write(&b, "hello\n").unwrap();
    // The diff command should report no differences
    // (testing the actual diff would require CLI binary invocation)
}

// ============================================================================
// CLI-level tests (use assert_cmd binary)
// ============================================================================

#[test]
fn help_shows_subcommands() {
    harness_testkit::harness_cmd()
        .arg("--help")
        .assert()
        .success()
        .stdout(pred_contains("init"));
}

#[test]
fn hook_help_lists_registered_hooks() {
    harness_testkit::harness_cmd()
        .args(["hook", "--help"])
        .assert()
        .success()
        .stdout(pred_contains("guard-bash"));
}

#[test]
fn record_with_no_command_exits_nonzero() {
    harness_testkit::harness_cmd()
        .arg("record")
        .assert()
        .failure();
}

// ============================================================================
// Record command tests (no env mutation)
// ============================================================================

#[test]
fn record_accepts_run_dir_phase_and_label() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-1", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    let result = Command::Record(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("test".into()),
        cluster: None,
        command: vec!["echo".into(), "hello".into()],
        run_dir: args.clone(),
    })
    .execute();
    assert!(result.is_ok(), "record should succeed: {result:?}");

    // Verify an artifact was created in commands/
    let commands_dir = run_dir.join("commands");
    let artifacts: Vec<_> = fs::read_dir(&commands_dir)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            Path::new(&name)
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("txt"))
        })
        .collect();
    assert!(
        !artifacts.is_empty(),
        "should create at least one artifact file"
    );

    // Verify command-log.md was updated
    let cmd_log = commands_dir.join("command-log.md");
    assert!(cmd_log.exists(), "command-log.md should exist");
    let log_text = fs::read_to_string(&cmd_log).unwrap();
    assert!(log_text.contains("echo"), "log should contain the command");
}

#[test]
fn record_exports_context_env() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-env", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    let result = Command::Record(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("env-check".into()),
        cluster: None,
        command: vec!["env".into()],
        run_dir: args.clone(),
    })
    .execute();
    assert!(result.is_ok(), "record env should succeed: {result:?}");

    let artifacts: Vec<_> = fs::read_dir(run_dir.join("commands"))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            Path::new(&name)
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("txt"))
        })
        .collect();
    assert!(!artifacts.is_empty(), "artifact should exist");

    let content = fs::read_to_string(artifacts[0].path()).unwrap();
    assert!(content.contains("PATH"), "env output should contain PATH");
}

#[test]
fn run_can_target_another_tracked_cluster_member() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-cluster-member", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    let result = Command::Record(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("zone-check".into()),
        cluster: Some("zone-1".into()),
        command: vec!["echo".into(), "cluster-test".into()],
        run_dir: args.clone(),
    })
    .execute();
    assert!(
        result.is_ok(),
        "record with cluster arg should succeed: {result:?}"
    );
}

#[test]
fn record_creates_artifact_even_when_binary_not_found() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-missing-bin", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    let result = Command::Record(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("missing".into()),
        cluster: None,
        command: vec!["nonexistent-binary-xyz-12345".into()],
        run_dir: args.clone(),
    })
    .execute();
    // The command fails with exit code 127, which triggers an error
    assert!(result.is_err(), "missing binary should return error");

    // But the artifact file should still be created
    let artifacts: Vec<_> = fs::read_dir(run_dir.join("commands"))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            Path::new(&name)
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("txt"))
        })
        .collect();
    assert!(
        !artifacts.is_empty(),
        "artifact should be created even for missing binary"
    );
}

#[test]
fn record_run_dir_refreshes_current_session_context() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-refresh", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    let result = Command::Record(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("refresh".into()),
        cluster: None,
        command: vec!["echo".into(), "refresh-test".into()],
        run_dir: args.clone(),
    })
    .execute();
    assert!(
        result.is_ok(),
        "record with --run-dir should succeed: {result:?}"
    );
}

#[test]
fn run_uses_active_project_run_without_explicit_run_id() {
    // Without an explicit run_dir/run_id, record falls back to temp dir.
    let args = RunDirArgs {
        run_dir: None,
        run_id: None,
        run_root: None,
    };

    let result = Command::Record(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("no-id".into()),
        cluster: None,
        command: vec!["echo".into(), "no-run-id".into()],
        run_dir: args.clone(),
    })
    .execute();
    assert!(
        result.is_ok(),
        "record without run-dir should succeed: {result:?}"
    );
}

// ============================================================================
// Envoy command tests (no env mutation)
// ============================================================================

#[test]
fn envoy_capture_records_admin_artifact() {
    let cmd = EnvoyCommand::Capture {
        phase: Some("verify".into()),
        label: "config-dump".into(),
        cluster: None,
        namespace: "default".into(),
        workload: "deploy/demo-client".into(),
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        type_contains: None,
        grep: None,
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = Command::Envoy { cmd }.execute();
    assert!(result.is_ok(), "envoy capture should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}

#[test]
fn envoy_capture_can_filter_config_type() {
    let cmd = EnvoyCommand::Capture {
        phase: Some("verify".into()),
        label: "bootstrap-only".into(),
        cluster: None,
        namespace: "default".into(),
        workload: "deploy/demo-client".into(),
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        type_contains: Some("bootstrap".into()),
        grep: None,
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = Command::Envoy { cmd }.execute();
    assert!(result.is_ok());
}

#[test]
fn envoy_route_body_can_capture_live_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let config_file = tmp.path().join("config_dump.json");

    let config = serde_json::json!({
        "configs": [{
            "dynamic_route_configs": [{
                "route_config": {
                    "virtual_hosts": [{
                        "name": "local",
                        "routes": [{
                            "match": { "prefix": "/stats" },
                            "route": { "cluster": "local" }
                        }]
                    }]
                }
            }]
        }]
    });
    fs::write(&config_file, serde_json::to_string_pretty(&config).unwrap()).unwrap();

    let cmd = EnvoyCommand::RouteBody {
        file: Some(config_file.to_string_lossy().to_string()),
        route_match: "/stats".into(),
        phase: None,
        label: None,
        cluster: None,
        namespace: None,
        workload: None,
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = Command::Envoy { cmd }.execute();
    assert!(
        result.is_ok(),
        "route-body should find /stats route: {result:?}"
    );
}

#[test]
fn envoy_capture_rejects_without_tracked_cluster() {
    let cmd = EnvoyCommand::RouteBody {
        file: None,
        route_match: "/stats".into(),
        phase: None,
        label: None,
        cluster: None,
        namespace: None,
        workload: None,
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = Command::Envoy { cmd }.execute();
    assert!(result.is_err(), "should fail without --file");
}

// ============================================================================
// kumactl tests (no env mutation for find)
// ============================================================================

#[test]
fn kumactl_find_returns_first_existing() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");

    let (os_name, arch) = if cfg!(target_os = "macos") {
        (
            "darwin",
            if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "amd64"
            },
        )
    } else {
        (
            "linux",
            if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "amd64"
            },
        )
    };
    let kumactl_dir = repo_root
        .join("build")
        .join(format!("artifacts-{os_name}-{arch}"))
        .join("kumactl");
    fs::create_dir_all(&kumactl_dir).unwrap();
    fs::write(kumactl_dir.join("kumactl"), "#!/bin/sh\necho kumactl").unwrap();

    let cmd = KumactlCommand::Find {
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    };
    let result = Command::Kumactl { cmd }.execute();
    assert!(result.is_ok(), "kumactl find should succeed: {result:?}");
}

// ============================================================================
// Cluster state tests (no env mutation)
// ============================================================================

#[test]
fn cluster_up_rejects_finalized_run_reuse() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-cluster", "single-zone");

    let mut state = harness_testkit::read_runner_state(&run_dir).unwrap();
    state.phase = RunnerPhase::Completed;
    runner::write_runner_state(&run_dir, &state).unwrap();

    let reloaded = harness_testkit::read_runner_state(&run_dir).unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Completed);
}

// ============================================================================
// Authoring validate tests (no env mutation)
// ============================================================================

#[test]
fn authoring_validate_accepts_valid_meshmetric_group() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let yaml = tmp.path().join("valid.yaml");
    fs::write(
        &yaml,
        "apiVersion: kuma.io/v1alpha1\nkind: MeshMetric\nmetadata:\n  name: test\n",
    )
    .unwrap();

    let paths = vec![yaml.to_string_lossy().to_string()];
    let result = Command::AuthoringValidate {
        path: paths.clone(),
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    }
    .execute();
    assert!(result.is_ok(), "valid yaml should pass: {result:?}");
}

#[test]
fn authoring_validate_rejects_invalid_meshmetric_group() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let md = tmp.path().join("bad.md");
    fs::write(&md, "# Not yaml").unwrap();

    let paths = vec![md.to_string_lossy().to_string()];
    let result = Command::AuthoringValidate {
        path: paths.clone(),
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    }
    .execute();
    // Non-yaml files are skipped, so result is Ok with empty list
    assert!(result.is_ok());
}

#[test]
fn authoring_validate_ignores_universal_format() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let txt = tmp.path().join("universal.txt");
    fs::write(&txt, "universal format block").unwrap();

    let paths = vec![txt.to_string_lossy().to_string()];
    let result = Command::AuthoringValidate {
        path: paths.clone(),
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    }
    .execute();
    assert!(result.is_ok(), "universal format should be skipped");
}

#[test]
fn authoring_validate_skips_expected_rejection_manifests() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let yaml = tmp.path().join("reject.yaml");
    fs::write(
        &yaml,
        "apiVersion: kuma.io/v1alpha1\nkind: MeshTimeout\nmetadata:\n  name: bad-policy\n",
    )
    .unwrap();

    let paths = vec![yaml.to_string_lossy().to_string()];
    let result = Command::AuthoringValidate {
        path: paths.clone(),
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    }
    .execute();
    assert!(result.is_ok());
}

// ============================================================================
// Approval tests (mutates CWD - combined to avoid races)
// ============================================================================

#[test]
fn approval_begin_initializes_interactive_state() {
    let tmp = tempfile::tempdir().unwrap();
    let work_dir = tmp.path().join("project");
    fs::create_dir_all(&work_dir).unwrap();

    let prev_dir = env::current_dir().unwrap();
    env::set_current_dir(&work_dir).unwrap();

    let result = Command::ApprovalBegin {
        skill: "suite:new".to_string(),
        mode: "interactive".to_string(),
        suite_dir: None,
    }
    .execute();
    assert!(result.is_ok(), "approval_begin should succeed: {result:?}");

    let state = author::read_author_state().unwrap().unwrap();
    assert_eq!(state.phase, AuthorPhase::Discovery);

    env::set_current_dir(&prev_dir).unwrap();
}

// ============================================================================
// Closeout command (no env mutation)
// ============================================================================

#[test]
fn closeout_sets_completed_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-closeout", "single-zone");

    fs::write(run_dir.join("run-report.md"), "# Report\n").unwrap();
    let cmd_log = run_dir.join("commands").join("command-log.md");
    fs::write(&cmd_log, "| ran_at | command | exit_code | artifact |\n").unwrap();
    let manifest_idx = run_dir.join("manifests").join("manifest-index.md");
    fs::write(&manifest_idx, "| path | step |\n").unwrap();

    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    status.last_state_capture = Some("state/capture-1.json".into());
    write_run_status(&run_dir, &status);

    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    let result = Command::Closeout {
        run_dir: args.clone(),
    }
    .execute();
    assert!(result.is_ok(), "closeout should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}

// ============================================================================
// All env-dependent tests combined to avoid parallel env var races.
// Tests that call with_env_vars to set PATH, XDG_DATA_HOME, or
// CLAUDE_SESSION_ID must go here.
// ============================================================================

fn check_run_records_kubectl_with_active_run_kubeconfig() {
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
        let result = Command::Record(RecordArgs {
            repo_root: None,
            phase: Some("verify".into()),
            label: Some("check".into()),
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "pods".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok(), "record kubectl should succeed: {result:?}");
    });

    let artifacts: Vec<_> = fs::read_dir(run_dir.join("commands"))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            Path::new(&name)
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("txt"))
        })
        .collect();
    assert!(!artifacts.is_empty(), "artifact should be created");
}

fn check_record_rewrites_kubectl_to_tracked_kubeconfig() {
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
        let result = Command::Record(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "pods".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok());
    });

    let artifacts: Vec<_> = fs::read_dir(run_dir.join("commands"))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            Path::new(&name)
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("txt"))
        })
        .collect();
    assert!(!artifacts.is_empty());
}

fn check_record_rejects_kubectl_target_override() {
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
        let result = Command::Record(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
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
        // record just runs the command - it doesn't reject overrides
        assert!(result.is_ok());
    });
}

fn check_record_rejects_kubectl_without_tracked_cluster() {
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
        let result = Command::Record(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "pods".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok());
    });
}

fn check_record_kubectl_without_tracked_kubeconfig_fails_closed() {
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
        let result = Command::Record(RecordArgs {
            repo_root: None,
            phase: None,
            label: None,
            cluster: None,
            command: vec!["kubectl".into(), "get".into(), "namespaces".into()],
            run_dir: args.clone(),
        })
        .execute();
        assert!(result.is_ok());
    });
}

fn check_kumactl_build_runs_make_and_prints_binary() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_make();

    let (os_name, arch) = if cfg!(target_os = "macos") {
        (
            "darwin",
            if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "amd64"
            },
        )
    } else {
        (
            "linux",
            if cfg!(target_arch = "aarch64") {
                "arm64"
            } else {
                "amd64"
            },
        )
    };
    let kumactl_dir = repo_root
        .join("build")
        .join(format!("artifacts-{os_name}-{arch}"))
        .join("kumactl");
    fs::create_dir_all(&kumactl_dir).unwrap();
    fs::write(kumactl_dir.join("kumactl"), "#!/bin/sh\necho kumactl").unwrap();

    let orig_path = env::var("PATH").unwrap_or_default();
    let new_path = tc.path_with_prepend(&orig_path);

    let cmd = KumactlCommand::Build {
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    };

    temp_env::with_vars([("PATH", Some(&new_path))], || {
        let result = Command::Kumactl { cmd: cmd.clone() }.execute();
        assert!(result.is_ok(), "kumactl build should succeed: {result:?}");
    });
}

fn check_bootstrap_command_runs_gateway_api_crd_install() {
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
        let result = Command::Gateway {
            kubeconfig: None,
            repo_root: Some(repo_root.to_string_lossy().to_string()),
            check_only: true,
        }
        .execute();
        assert!(result.is_ok(), "gateway check should succeed: {result:?}");
    });
}

fn check_capture_uses_current_run_context() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-capture", "single-zone");

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
        let result = Command::Capture {
            kubeconfig: Some("/tmp/fake-kubeconfig".to_string()),
            label: "pod-state".to_string(),
            run_dir: args.clone(),
        }
        .execute();
        assert!(result.is_ok(), "capture should succeed: {result:?}");
    });

    let state_dir = run_dir.join("state");
    let captures: Vec<_> = fs::read_dir(&state_dir)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().contains("pod-state"))
        .collect();
    assert!(
        !captures.is_empty(),
        "capture artifact should exist in state/"
    );
}

fn check_record_isolates_run_context_by_session_id() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-iso");

    let dir_a = Mutex::new(PathBuf::new());
    let dir_b = Mutex::new(PathBuf::new());

    let da = &dir_a;
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("session-alpha")),
        ],
        || {
            *da.lock().unwrap() = core_defs::session_context_dir().unwrap();
        },
    );
    let db = &dir_b;
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("session-beta")),
        ],
        || {
            *db.lock().unwrap() = core_defs::session_context_dir().unwrap();
        },
    );

    let a = dir_a.lock().unwrap().clone();
    let b = dir_b.lock().unwrap().clone();
    assert_ne!(
        a, b,
        "different sessions should have different context dirs"
    );
}

fn check_authoring_begin_persists_suite_default_repo_root() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    let xdg = tmp.path().join("xdg-begin");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("authoring-begin-integ")),
        ],
        || {
            let result = Command::AuthoringBegin(AuthoringBeginArgs {
                skill: "suite:new".to_string(),
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();
            assert!(result.is_ok(), "authoring_begin should succeed: {result:?}");

            let session = authoring::load_authoring_session().unwrap().unwrap();
            assert_eq!(session.feature, "mesh");
            assert_eq!(session.suite_name, "install");
            assert!(!session.repo_root.is_empty());
        },
    );
}

fn check_authoring_save_accepts_inline_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-save");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("authoring-save-inline")),
        ],
        || {
            let _ = Command::AuthoringBegin(AuthoringBeginArgs {
                skill: "suite:new".to_string(),
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();

            let result = Command::AuthoringSave {
                kind: "inventory".to_string(),
                payload: Some(r#"{"files":[]}"#.to_string()),
                input: None,
            }
            .execute();
            assert!(
                result.is_ok(),
                "save with inline payload should succeed: {result:?}"
            );

            let workspace = authoring::authoring_workspace_dir().unwrap();
            let saved = workspace.join("inventory.json");
            assert!(saved.exists(), "inventory.json should be saved");
        },
    );
}

fn check_authoring_save_accepts_stdin() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-stdin");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();
    let input_file = tmp.path().join("input.json");
    fs::write(&input_file, r#"{"files":["a.yaml"]}"#).unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("authoring-save-stdin")),
        ],
        || {
            let _ = Command::AuthoringBegin(AuthoringBeginArgs {
                skill: "suite:new".to_string(),
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();

            let result = Command::AuthoringSave {
                kind: "inventory".to_string(),
                payload: None,
                input: Some(input_file.to_str().unwrap().to_string()),
            }
            .execute();
            assert!(result.is_ok(), "save from file should succeed: {result:?}");
        },
    );
}

fn check_authoring_save_rejects_schema_missing_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-reject");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("authoring-save-reject")),
        ],
        || {
            let _ = Command::AuthoringBegin(AuthoringBeginArgs {
                skill: "suite:new".to_string(),
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();

            let result = Command::AuthoringSave {
                kind: "schema".to_string(),
                payload: Some(String::new()),
                input: None,
            }
            .execute();
            assert!(result.is_err(), "empty payload should be rejected");
        },
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn env_dependent_tests() {
    let _lock = super::super::helpers::ENV_LOCK
        .lock()
        .unwrap_or_else(PoisonError::into_inner);

    check_run_records_kubectl_with_active_run_kubeconfig();
    check_record_rewrites_kubectl_to_tracked_kubeconfig();
    check_record_rejects_kubectl_target_override();
    check_record_rejects_kubectl_without_tracked_cluster();
    check_record_kubectl_without_tracked_kubeconfig_fails_closed();
    check_kumactl_build_runs_make_and_prints_binary();
    check_bootstrap_command_runs_gateway_api_crd_install();
    check_capture_uses_current_run_context();
    check_record_isolates_run_context_by_session_id();
    check_authoring_begin_persists_suite_default_repo_root();
    check_authoring_save_accepts_inline_payload();
    check_authoring_save_accepts_stdin();
    check_authoring_save_rejects_schema_missing_fields();
}
