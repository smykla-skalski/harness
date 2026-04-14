use std::env;
use std::fs;
use std::sync::PoisonError;

use harness::run::RunDirArgs;
use harness::run::{ApplyArgs, CaptureArgs, PreflightArgs, ValidateArgs};
use harness_testkit::{FakeToolchain, init_run_with_suite};

use super::super::helpers::*;

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn capture_uses_run_context() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-capture", "single-zone");

    let kc_path = tmp.path().join("kubeconfig");
    fs::write(&kc_path, "apiVersion: v1\nkind: Config\n").unwrap();
    seed_cluster_state(&run_dir, &kc_path.to_string_lossy());

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{\"items\": []}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let result = capture_cmd(CaptureArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            label: "post-deploy".to_string(),
            run_dir: rda,
        })
        .execute();
        assert!(result.is_ok(), "capture should succeed: {result:?}");
        assert_eq!(result.unwrap(), 0);

        let invocations = tc.invocations("kubectl");
        assert!(!invocations.is_empty(), "kubectl should have been invoked");
        let invoc = invocations[0].to_lowercase();
        assert!(
            invoc.contains("get"),
            "kubectl should have run get: {invoc}"
        );
        assert!(
            invoc.contains("pods"),
            "kubectl should have queried pods: {invoc}"
        );

        let state_dir = run_dir.join("state");
        let entries: Vec<_> = fs::read_dir(&state_dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().starts_with("post-deploy-"))
            .collect();
        assert!(
            !entries.is_empty(),
            "capture should create a state file in {state_dir:?}"
        );
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn apply_reuses_prepared() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-apply", "single-zone");

    let manifest_path = run_dir.join("manifests").join("g01-configure.yaml");
    fs::write(
        &manifest_path,
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: test\n  namespace: default\ndata:\n  key: value\n",
    )
    .unwrap();

    let kc_path = tmp.path().join("kubeconfig");
    fs::write(&kc_path, "apiVersion: v1\nkind: Config\n").unwrap();
    seed_cluster_state(&run_dir, &kc_path.to_string_lossy());

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("configmap/test configured");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let manifests = vec![manifest_path.to_string_lossy().to_string()];
        let result = apply_cmd(ApplyArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            cluster: None,
            manifest: manifests,
            step: Some("configure".to_string()),
            run_dir: rda,
        })
        .execute();
        assert!(result.is_ok(), "apply should succeed: {result:?}");
        assert_eq!(result.unwrap(), 0);

        let invocations = tc.invocations("kubectl");
        assert!(!invocations.is_empty(), "kubectl should have been invoked");
        let invoc = &invocations[0];
        assert!(invoc.contains("apply"), "kubectl should run apply: {invoc}");
        assert!(invoc.contains("-f"), "kubectl should use -f flag: {invoc}");
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn apply_validate_shorthand() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-shorthand", "single-zone");

    let prepared_dir = run_dir.join("manifests").join("prepared").join("groups");
    fs::create_dir_all(&prepared_dir).unwrap();
    fs::write(
        prepared_dir.join("g01-configure.yaml"),
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: shorthand\n  namespace: default\n",
    )
    .unwrap();

    let kc_path = tmp.path().join("kubeconfig");
    fs::write(&kc_path, "apiVersion: v1\nkind: Config\n").unwrap();
    seed_cluster_state(&run_dir, &kc_path.to_string_lossy());

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("configmap/shorthand configured");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };
        let manifests = vec!["g01-configure.yaml".to_string()];
        let result = apply_cmd(ApplyArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            cluster: None,
            manifest: manifests,
            step: None,
            run_dir: rda,
        })
        .execute();
        assert!(
            result.is_ok(),
            "apply with shorthand should succeed: {result:?}"
        );
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn validate_uses_api_version() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();

    let manifest_path = tmp.path().join("test-resource.yaml");
    fs::write(
        &manifest_path,
        "apiVersion: kuma.io/v1alpha1\nkind: MeshTimeout\nmetadata:\n  name: timeout-policy\nspec:\n  targetRef:\n    kind: Mesh\n",
    )
    .unwrap();

    let kc_path = tmp.path().join("kubeconfig");
    fs::write(&kc_path, "apiVersion: v1\nkind: Config\n").unwrap();

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let result = validate_cmd(ValidateArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            manifest: manifest_path.to_string_lossy().to_string(),
            output: None,
        })
        .execute();
        assert!(result.is_ok(), "validate should succeed: {result:?}");
        assert_eq!(result.unwrap(), 0);

        let invocations = tc.invocations("kubectl");
        assert!(
            invocations.len() >= 2,
            "kubectl should be invoked multiple times (explain + dry-run + diff): got {}",
            invocations.len()
        );
        let explain_invoc = &invocations[0];
        assert!(
            explain_invoc.contains("explain"),
            "first kubectl call should be explain: {explain_invoc}"
        );
        assert!(
            explain_invoc.contains("kuma.io/v1alpha1"),
            "explain should use the manifest's apiVersion: {explain_invoc}"
        );

        let output_path = manifest_path.with_extension("validation.json");
        assert!(
            output_path.exists(),
            "validation output should be written to {output_path:?}"
        );
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn capture_marks_preflight_complete() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-cap-pf", "single-zone");

    let kc_path = tmp.path().join("kubeconfig");
    fs::write(&kc_path, "apiVersion: v1\nkind: Config\n").unwrap();
    seed_cluster_state(&run_dir, &kc_path.to_string_lossy());

    let mut tc = FakeToolchain::new();
    tc.add_kubectl("{\"items\": []}");
    let orig_path = env::var("PATH").unwrap_or_default();

    temp_env::with_vars([("PATH", Some(&tc.path_with_prepend(&orig_path)))], || {
        let rda = RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        };

        let pf_result = preflight_cmd(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda.clone(),
        })
        .execute();
        assert!(pf_result.is_ok(), "preflight should succeed: {pf_result:?}");

        let cap_result = capture_cmd(CaptureArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            label: "post-preflight".to_string(),
            run_dir: rda,
        })
        .execute();
        assert!(cap_result.is_ok(), "capture should succeed: {cap_result:?}");
        assert_eq!(cap_result.unwrap(), 0);

        let state_dir = run_dir.join("state");
        let entries: Vec<_> = fs::read_dir(&state_dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("post-preflight-")
            })
            .collect();
        assert!(
            !entries.is_empty(),
            "capture after preflight should create state file"
        );
    });
}
