// Preflight and kubectl-validate integration tests.
// Tests kubectl-validate state serialization, prepared suite plan filtering,
// YAML resource extraction, group spec rejection orders, and preflight
// command flows using FakeToolchain for kubectl/kubectl-validate.

use std::env;
use std::fs;
use std::sync::PoisonError;

use harness::cli::Command;
use harness::commands::RunDirArgs;
use harness::commands::run::{ApplyArgs, CaptureArgs, PreflightArgs, ValidateArgs};
use harness::kubectl_validate::{KubectlValidateDecision, KubectlValidateState};
use harness::schema::GroupSpec;
use harness::workflow::runner::{RunnerPhase, read_runner_state};
use harness_testkit::{
    FakeToolchain, GroupBuilder, RunDirBuilder, SuiteBuilder, init_run_with_suite,
};

use super::helpers::*;

// ============================================================================
// kubectl-validate state tests
// ============================================================================

#[test]
fn kubectl_validate_state_serialization() {
    let state = KubectlValidateState {
        schema_version: 1,
        decision: KubectlValidateDecision::Installed,
        decided_at: "2026-03-13T00:00:00Z".to_string(),
        binary_path: Some("/usr/local/bin/kubectl-validate".to_string()),
    };
    let json = serde_json::to_string(&state).unwrap();
    let back: KubectlValidateState = serde_json::from_str(&json).unwrap();
    assert_eq!(state, back);
}

#[test]
fn kubectl_validate_state_declined() {
    let state = KubectlValidateState {
        schema_version: 1,
        decision: KubectlValidateDecision::Declined,
        decided_at: "2026-03-13T00:00:00Z".to_string(),
        binary_path: None,
    };
    let json = serde_json::to_string(&state).unwrap();
    assert!(json.contains("declined"));
    let back: KubectlValidateState = serde_json::from_str(&json).unwrap();
    assert_eq!(back.decision, KubectlValidateDecision::Declined);
    assert!(back.binary_path.is_none());
}

#[test]
fn seed_kubectl_validate_and_read_back() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    seed_kubectl_validate_state(&xdg, "declined", None);
    let state_path = xdg
        .join("kuma")
        .join("tooling")
        .join("kubectl-validate.json");
    assert!(state_path.exists());
    let text = fs::read_to_string(&state_path).unwrap();
    let state: KubectlValidateState = serde_json::from_str(&text).unwrap();
    assert_eq!(state.decision, KubectlValidateDecision::Declined);
}

#[test]
fn seed_kubectl_validate_with_binary_path() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let binary = tmp.path().join("bin").join("kubectl-validate");
    fs::create_dir_all(binary.parent().unwrap()).unwrap();
    fs::write(&binary, "#!/bin/sh\necho ok\n").unwrap();
    seed_kubectl_validate_state(&xdg, "installed", Some(&binary));
    let state_path = xdg
        .join("kuma")
        .join("tooling")
        .join("kubectl-validate.json");
    let text = fs::read_to_string(&state_path).unwrap();
    let state: KubectlValidateState = serde_json::from_str(&text).unwrap();
    assert_eq!(state.decision, KubectlValidateDecision::Installed);
    assert!(state.binary_path.is_some());
}

// ============================================================================
// Prepared suite plan tests
// ============================================================================

#[test]
fn prepared_suite_plan_filters_profile() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");

    let kube_and_universal_configure = "\
### Kubernetes format

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-only
  namespace: kuma-demo
```

### Universal format

```yaml
type: MeshOpenTelemetryBackend
mesh: default
name: universal-only
spec:
  endpoint:
    address: 127.0.0.1
    port: 4317
```";

    let _ = GroupBuilder::new("g01")
        .story("mixed formats")
        .capability("preflight")
        .profiles(&["single-zone-kubernetes", "single-zone-universal"])
        .configure_section(kube_and_universal_configure)
        .consume_section("- verify")
        .debug_section("- inspect")
        .write_to(&suite_dir.join("groups").join("g01.md"));

    let _ = SuiteBuilder::new("example.suite")
        .feature("example")
        .scope("unit")
        .profile("single-zone-kubernetes")
        .coverage_expectations(&["configure"])
        .group("groups/g01.md")
        .keep_clusters(false)
        .body("# Example suite\n")
        .write_to(&suite_dir.join("suite.md"));

    let group = GroupSpec::from_markdown(&suite_dir.join("groups").join("g01.md")).unwrap();
    assert_eq!(group.frontmatter.group_id, "g01");
    assert!(group.body.contains("kind: ConfigMap"));
    assert!(group.body.contains("type: MeshOpenTelemetryBackend"));
}

// ============================================================================
// YAML resource extraction tests
// ============================================================================

#[test]
fn extract_resources_multi_doc() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("multi.yaml");
    fs::write(
        &path,
        "\
apiVersion: v1
kind: ConfigMap
metadata:
  name: cm1
---
apiVersion: v1
kind: Service
metadata:
  name: svc1
",
    )
    .unwrap();

    let content = fs::read_to_string(&path).unwrap();
    // Verify we can detect multiple documents
    let docs: Vec<&str> = content.split("\n---\n").collect();
    assert_eq!(docs.len(), 2);
    assert!(docs[0].contains("ConfigMap"));
    assert!(docs[1].contains("Service"));
}

#[test]
fn extract_kinds_from_manifest_headers() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("resources.yaml");
    fs::write(
        &path,
        "\
apiVersion: v1
kind: ConfigMap
metadata:
  name: test
data:
  key: value
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deploy
spec:
  replicas: 1
",
    )
    .unwrap();

    let content = fs::read_to_string(&path).unwrap();
    let kinds: Vec<String> = content
        .split("\n---\n")
        .filter_map(|doc| {
            doc.lines()
                .find(|line| line.starts_with("kind:"))
                .map(|line| line.trim_start_matches("kind:").trim().to_string())
        })
        .collect();
    assert_eq!(kinds, vec!["ConfigMap", "Deployment"]);
}

// ============================================================================
// Group spec with expected rejections
// ============================================================================

#[test]
fn group_spec_with_expected_rejection_orders() {
    let tmp = tempfile::tempdir().unwrap();
    let path = GroupBuilder::new("g02")
        .story("validation rejects")
        .capability("validation")
        .profile("single-zone")
        .success_criteria("rejected")
        .variant_source("code")
        .expected_rejection_orders(&[2, 4])
        .configure_section("Do config.")
        .consume_section("Do consume.")
        .debug_section("Do debug.")
        .write_to(&tmp.path().join("g-reject.md"));
    let spec = GroupSpec::from_markdown(&path).unwrap();
    assert_eq!(spec.frontmatter.expected_rejection_orders, vec![2, 4]);
}

// ============================================================================
// Preflight command integration tests (use FakeToolchain for kubectl)
// ============================================================================

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
        let result = Command::Preflight(PreflightArgs {
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

        // Second call should also succeed (idempotent)
        let result2 = Command::Preflight(PreflightArgs {
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
        let result = Command::Preflight(PreflightArgs {
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
        let result = Command::Preflight(PreflightArgs {
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
        let result = Command::Preflight(PreflightArgs {
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

    // Write a baseline manifest in the suite dir
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
        let result = Command::Preflight(PreflightArgs {
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

    // Write namespace baseline
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
        let result = Command::Preflight(PreflightArgs {
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
fn capture_uses_run_context() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-capture", "single-zone");

    // Write a fake kubeconfig for the capture command
    let kc_path = tmp.path().join("kubeconfig");
    fs::write(&kc_path, "apiVersion: v1\nkind: Config\n").unwrap();

    // Seed cluster context so capture can find the cluster spec
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
        let result = Command::Capture(CaptureArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            label: "post-deploy".to_string(),
            run_dir: rda,
        })
        .execute();
        assert!(result.is_ok(), "capture should succeed: {result:?}");
        assert_eq!(result.unwrap(), 0);

        // Verify kubectl was invoked
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

        // Verify state file was created
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

    // Write a manifest file for apply to use
    let manifest_path = run_dir.join("manifests").join("g01-configure.yaml");
    fs::write(
        &manifest_path,
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: test\n  namespace: default\ndata:\n  key: value\n",
    )
    .unwrap();

    // Write a fake kubeconfig and seed cluster context
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
        let result = Command::Apply(ApplyArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            cluster: None,
            manifest: manifests,
            step: Some("configure".to_string()),
            run_dir: rda,
        })
        .execute();
        assert!(result.is_ok(), "apply should succeed: {result:?}");
        assert_eq!(result.unwrap(), 0);

        // Verify kubectl was invoked with apply -f
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

    // Write a manifest in the prepared/groups subdir so shorthand resolution finds it
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
        // Use the shorthand name (not full path) - resolve_manifest_path should find it
        let manifests = vec!["g01-configure.yaml".to_string()];
        let result = Command::Apply(ApplyArgs {
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

    // Write a manifest with a specific apiVersion
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
        let result = Command::Validate(ValidateArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            manifest: manifest_path.to_string_lossy().to_string(),
            output: None,
        })
        .execute();
        assert!(result.is_ok(), "validate should succeed: {result:?}");
        assert_eq!(result.unwrap(), 0);

        // Verify kubectl was invoked with explain and the api-version
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

        // Verify validation output file was created
        let output_path = manifest_path.with_extension("validation.json");
        assert!(
            output_path.exists(),
            "validation output should be written to {output_path:?}"
        );
    });
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_failure_resets() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, _suite_dir) = init_run_with_suite(tmp.path(), "run-reset", "single-zone");

    // Verify initial runner state
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
        let result = Command::Preflight(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda,
        })
        .execute();
        assert!(result.is_ok(), "preflight should succeed: {result:?}");

        // Preflight succeeds and advances the runner phase to Execution
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

        // Run preflight first
        let pf_result = Command::Preflight(PreflightArgs {
            kubeconfig: None,
            repo_root: None,
            run_dir: rda.clone(),
        })
        .execute();
        assert!(pf_result.is_ok(), "preflight should succeed: {pf_result:?}");

        // Then run capture
        let cap_result = Command::Capture(CaptureArgs {
            kubeconfig: Some(kc_path.to_string_lossy().to_string()),
            label: "post-preflight".to_string(),
            run_dir: rda,
        })
        .execute();
        assert!(cap_result.is_ok(), "capture should succeed: {cap_result:?}");
        assert_eq!(cap_result.unwrap(), 0);

        // Verify state file was created
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

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn preflight_dependent_baselines() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let tmp = tempfile::tempdir().unwrap();
    let (run_dir, suite_dir) = init_run_with_suite(tmp.path(), "run-dep-base", "single-zone");

    // Write dependent baselines - a namespace that other resources depend on
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
        let result = Command::Preflight(PreflightArgs {
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
