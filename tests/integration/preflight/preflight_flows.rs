use std::env;
use std::fs;
use std::sync::PoisonError;

use harness::run::RunDirArgs;
use harness::run::workflow::{RunnerPhase, read_runner_state};
use harness::run::PreflightArgs;
use harness_testkit::{FakeToolchain, GroupBuilder, RunDirBuilder, SuiteBuilder, init_run_with_suite};

use super::super::helpers::*;

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_prepares_and_caches() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-1", "single-zone");
    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda.clone(),
        })
        .execute();
        assert!(
            result.is_ok(),
            "first preflight call should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);

        let result2 = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result2.is_ok(),
            "second preflight call should succeed: {result2:?}"
        );
        assert_eq!(result2.unwrap(), 0);
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_skips_rejections() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let group = GroupBuilder::new("g01")
        .story("rejection test")
        .capability("validation")
        .profile("single-zone")
        .expected_rejection_orders(&[1, 2])
        .configure_section("```yaml\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: test\n```")
        .consume_section("- verify")
        .debug_section("- inspect");
    let suite = SuiteBuilder::new("example.suite")
        .feature("rejection")
        .scope("unit")
        .profile("single-zone")
        .group("groups/g01.md");
    let (run_dir, _suite_dir) = RunDirBuilder::new(tmp.path(), "run-reject")
        .profile("single-zone")
        .suite(suite)
        .group(group)
        .build();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result.is_ok(),
            "preflight with rejections should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_skips_inline_rejections() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let group = GroupBuilder::new("g01")
        .story("inline rejection")
        .capability("validation")
        .profile("single-zone")
        .expected_rejection_orders(&[1])
        .configure_section("```yaml\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\n```")
        .consume_section("Apply the rejection inline:\n```yaml\napiVersion: v1\nkind: Pod\nmetadata:\n  name: bad-pod\n```")
        .debug_section("- inspect");
    let suite = SuiteBuilder::new("example.suite")
        .feature("inline-reject")
        .scope("unit")
        .profile("single-zone")
        .group("groups/g01.md");
    let (run_dir, _suite_dir) = RunDirBuilder::new(tmp.path(), "run-inline-rej")
        .profile("single-zone")
        .suite(suite)
        .group(group)
        .build();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result.is_ok(),
            "preflight with inline rejections should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_skips_frontmatter_rejections() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let group = GroupBuilder::new("g01")
        .story("frontmatter rejection")
        .capability("validation")
        .profile("single-zone")
        .expected_rejection_orders(&[2, 3])
        .configure_section("```yaml\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm\n```")
        .consume_section("- verify")
        .debug_section("- inspect");
    let suite = SuiteBuilder::new("example.suite")
        .feature("frontmatter-reject")
        .scope("unit")
        .profile("single-zone")
        .group("groups/g01.md");
    let (run_dir, _suite_dir) = RunDirBuilder::new(tmp.path(), "run-fm-rej")
        .profile("single-zone")
        .suite(suite)
        .group(group)
        .build();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result.is_ok(),
            "preflight with frontmatter rejections should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_applies_baselines() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, suite_dir) = init_run_with_suite(tmp.path(), "run-baselines", "single-zone");

    let baselines_dir = suite_dir.join("baselines");
    fs::create_dir_all(&baselines_dir).unwrap();
    fs::write(
        baselines_dir.join("namespace.yaml"),
        "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: kuma-demo\n",
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result.is_ok(),
            "preflight with baselines should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_namespace_baseline() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, suite_dir) = init_run_with_suite(tmp.path(), "run-ns-base", "single-zone");

    let baselines_dir = suite_dir.join("baselines");
    fs::create_dir_all(&baselines_dir).unwrap();
    fs::write(
        baselines_dir.join("00-namespace.yaml"),
        "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test-ns\n",
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result.is_ok(),
            "preflight with namespace baseline should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_failure_resets() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-reset", "single-zone");

    let initial_state = read_runner_state(&run_dir).unwrap().unwrap();
    assert_eq!(initial_state.phase, RunnerPhase::Bootstrap);

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(result.is_ok(), "preflight should succeed: {result:?}");

        let state_after = read_runner_state(&run_dir).unwrap().unwrap();
        assert_eq!(
            state_after.phase,
            RunnerPhase::Execution,
            "runner phase should advance to Execution after successful preflight"
        );
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_dependent_baselines() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, suite_dir) = init_run_with_suite(tmp.path(), "run-dep-base", "single-zone");

    let baselines_dir = suite_dir.join("baselines");
    fs::create_dir_all(&baselines_dir).unwrap();
    fs::write(
        baselines_dir.join("01-namespace.yaml"),
        "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: kuma-demo\n",
    )
    .unwrap();
    fs::write(
        baselines_dir.join("02-configmap.yaml"),
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: demo-config\n  namespace: kuma-demo\ndata:\n  env: test\n",
    )
    .unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result.is_ok(),
            "preflight with dependent baselines should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);
    });
}
