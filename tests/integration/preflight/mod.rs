// Preflight and kubectl-validate integration tests.
// Tests kubectl-validate state serialization, prepared suite plan filtering,
// YAML resource extraction, group spec rejection orders, and preflight
// command flows using FakeToolchain for kubectl/kubectl-validate.

use std::fs;

use harness::run::GroupSpec;
use harness_testkit::{GroupBuilder, SuiteBuilder};

use super::helpers::*;

mod command_flows;
mod preflight_flows;

#[test]
fn seed_kubectl_validate_and_read_back() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    seed_kubectl_validate_state(&xdg, "declined", None);
    let state_path = xdg
        .join("harness")
        .join("tooling")
        .join("kubectl-validate.json");
    assert!(state_path.exists());
    let text = fs::read_to_string(&state_path).unwrap();
    let state: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(state["decision"], "declined");
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
        .join("harness")
        .join("tooling")
        .join("kubectl-validate.json");
    let text = fs::read_to_string(&state_path).unwrap();
    let state: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(state["decision"], "installed");
    assert_eq!(
        state["binary_path"].as_str(),
        Some(binary.to_string_lossy().as_ref())
    );
}

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
