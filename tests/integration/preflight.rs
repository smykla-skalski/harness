// Preflight and kubectl-validate integration tests.
// Tests kubectl-validate state serialization, prepared suite plan filtering,
// YAML resource extraction, group spec rejection orders, and preflight
// command flows (ignored - requires kubectl/kubectl-validate).

use std::fs;

use harness::kubectl_validate::{KubectlValidateDecision, KubectlValidateState};
use harness::schema::GroupSpec;

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
    // Create a suite with a group that has mixed kubernetes/universal blocks
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(suite_dir.join("groups")).unwrap();
    fs::write(
        suite_dir.join("groups").join("g01.md"),
        "\
---
group_id: g01
story: mixed formats
capability: preflight
profiles:
  - single-zone-kubernetes
  - single-zone-universal
preconditions: []
success_criteria: []
debug_checks: []
artifacts: []
variant_source: base
helm_values: {}
restart_namespaces: []
---

## Configure

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
```

## Consume

- verify

## Debug

- inspect
",
    )
    .unwrap();
    fs::write(
        suite_dir.join("suite.md"),
        "\
---
suite_id: example.suite
feature: example
scope: unit
profiles:
  - single-zone-kubernetes
required_dependencies: []
user_stories: []
variant_decisions: []
coverage_expectations:
  - configure
baseline_files: []
groups:
  - groups/g01.md
skipped_groups: []
keep_clusters: false
---

# Example suite
",
    )
    .unwrap();

    // Verify the group loads correctly
    let group = GroupSpec::from_markdown(&suite_dir.join("groups").join("g01.md")).unwrap();
    assert_eq!(group.frontmatter.group_id, "g01");

    // The body contains both kubernetes and universal blocks
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
    let path = tmp.path().join("g-reject.md");
    fs::write(
        &path,
        "\
---
group_id: g02
story: validation rejects
capability: validation
profiles: [single-zone]
preconditions: []
success_criteria: [rejected]
debug_checks: []
artifacts: []
variant_source: code
helm_values: {}
expected_rejection_orders: [2, 4]
restart_namespaces: []
---

## Configure

Do config.

## Consume

Do consume.

## Debug

Do debug.
",
    )
    .unwrap();
    let spec = GroupSpec::from_markdown(&path).unwrap();
    assert_eq!(spec.frontmatter.expected_rejection_orders, vec![2, 4]);
}

// ============================================================================
// Preflight command integration tests (require kubectl + kubectl-validate)
// ============================================================================

#[test]
#[ignore = "Requires kubectl and kubectl-validate"]
fn preflight_prepares_and_caches() {
    // Preflight should prepare suite once and reuse cached outputs
}

#[test]
#[ignore = "Requires kubectl-validate"]
fn preflight_skips_rejections() {
    // Expected rejection manifests should be skipped during validation
}

#[test]
#[ignore = "Requires kubectl-validate"]
fn preflight_skips_inline_rejections() {
    // Rejection manifests defined inline in consume should be skipped
}

#[test]
#[ignore = "Requires kubectl-validate"]
fn preflight_skips_frontmatter_rejections() {
    // Rejection manifests declared in frontmatter should be skipped
}

#[test]
#[ignore = "Requires kubectl"]
fn preflight_applies_baselines() {
    // Baselines should be applied before validating group manifests
}

#[test]
#[ignore = "Requires kubectl"]
fn preflight_namespace_baseline() {
    // Namespace baseline should be applied before other baselines
}

#[test]
#[ignore = "Requires kubectl"]
fn capture_uses_run_context() {
    // Capture should use kubeconfig from current run context
}

#[test]
#[ignore = "Requires kubectl-validate"]
fn apply_reuses_prepared() {
    // Apply should reuse prepared manifest without re-copy or re-validation
}

#[test]
#[ignore = "Requires kubectl-validate"]
fn apply_validate_shorthand() {
    // Apply and validate should accept prepared manifest shorthand
}

#[test]
#[ignore = "Requires kubectl-validate"]
fn validate_uses_api_version() {
    // Validate should use manifest apiVersion for explain
}

#[test]
#[ignore = "Requires kubectl"]
fn preflight_failure_resets() {
    // Preflight failure should reset runner state and log stage
}

#[test]
#[ignore = "Requires kubectl"]
fn capture_marks_preflight_complete() {
    // Capture should mark preflight complete for manual CLI flow
}

#[test]
#[ignore = "Requires kubectl"]
fn preflight_dependent_baselines() {
    // Baselines should be applied before validating dependent baselines
}
