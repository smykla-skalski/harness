use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::*;
use crate::infra::blocks::kuma::defaults;
use crate::infra::blocks::{ContainerConfig, ContainerPort, FakeContainerRuntime};
use crate::infra::io::read_json_typed;
use crate::run::application::RunApplication;
use crate::run::context::{PreflightArtifact, RunLayout};
use crate::run::services::service_lifecycle::{
    read_service_container_rows, run_service_filter, service_container_ports, service_probe_port,
};
use crate::run::workflow::{
    PreflightStatus, RunnerPhase, initialize_runner_state, read_runner_state,
};
use crate::run::{PreparedSuiteArtifact, RunCounts, RunStatus, Verdict};

fn write_suite(dir: &Path) -> PathBuf {
    let suite_dir = dir.join("suite");
    fs::create_dir_all(suite_dir.join("baseline")).unwrap();
    fs::create_dir_all(suite_dir.join("groups")).unwrap();
    fs::write(
        suite_dir.join("baseline").join("namespace.yaml"),
        "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: demo\n",
    )
    .unwrap();
    fs::write(
        suite_dir.join("groups").join("g01.md"),
        r"---
group_id: g01
story: demo
capability: demo
profiles: [single-zone]
preconditions: []
success_criteria: [done]
debug_checks: [logs]
artifacts: []
variant_source: code
helm_values:
  app.replicas: 1
restart_namespaces: [kuma-system]
expected_rejection_orders: [2]
---

## Configure

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: one
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: two
```

## Consume

observe

## Debug

debug
",
    )
    .unwrap();
    let suite_path = suite_dir.join("suite.md");
    fs::write(
        &suite_path,
        r"---
suite_id: demo.suite
feature: demo
scope: unit
profiles: [single-zone]
requires: []
user_stories: []
variant_decisions: []
coverage_expectations: []
baseline_files: [baseline/namespace.yaml]
groups: [groups/g01.md]
skipped_groups: []
keep_clusters: false
---

# Demo Suite
",
    )
    .unwrap();
    suite_path
}

fn write_run(layout: &RunLayout, suite_path: &Path) {
    layout.ensure_dirs().unwrap();
    let suite_dir = suite_path.parent().unwrap();
    let metadata = RunMetadata {
        run_id: layout.run_id.clone(),
        suite_id: "demo.suite".to_string(),
        suite_path: suite_path.display().to_string(),
        suite_dir: suite_dir.display().to_string(),
        profile: "single-zone".to_string(),
        repo_root: suite_dir.display().to_string(),
        keep_clusters: false,
        created_at: "2026-03-16T00:00:00Z".to_string(),
        user_stories: vec![],
        requires: vec![],
    };
    let status = RunStatus {
        run_id: layout.run_id.clone(),
        suite_id: "demo.suite".to_string(),
        profile: "single-zone".to_string(),
        started_at: "2026-03-16T00:00:00Z".to_string(),
        overall_verdict: Verdict::Pending,
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: vec![],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    };
    fs::write(
        layout.metadata_path(),
        serde_json::to_string_pretty(&metadata).unwrap(),
    )
    .unwrap();
    fs::write(
        layout.status_path(),
        serde_json::to_string_pretty(&status).unwrap(),
    )
    .unwrap();
}

fn prepare_preflight_run(dir: &Path, run_id: &str) -> RunLayout {
    let suite_path = write_suite(dir);
    let layout = RunLayout::from_run_dir(&dir.join("runs").join(run_id));
    write_run(&layout, &suite_path);
    layout
}

fn assert_prepared_suite_summary(artifact: &PreparedSuiteArtifact) {
    assert_eq!(artifact.baselines.len(), 1);
    assert_eq!(artifact.groups.len(), 1);
    assert_eq!(artifact.groups[0].manifests.len(), 2);
}

fn assert_prepared_suite_files(layout: &RunLayout) {
    assert!(layout.prepared_suite_path().exists());
    assert!(layout.preflight_artifact_path().exists());
    assert!(
        layout
            .run_dir()
            .join("manifests/prepared/baseline/baseline/namespace.yaml")
            .exists()
    );
    assert!(
        layout
            .run_dir()
            .join("manifests/prepared/groups/g01/01.yaml")
            .exists()
    );
    assert!(
        layout
            .run_dir()
            .join("manifests/prepared/groups/g01/02.yaml.validate.txt")
            .exists()
    );
}

#[test]
fn save_preflight_outputs_materializes_artifacts() {
    let dir = tempfile::tempdir().unwrap();
    let layout = prepare_preflight_run(dir.path(), "run-1");

    let ctx = RunContext::from_run_dir(&layout.run_dir()).unwrap();
    let run = RunApplication::from_context(ctx);
    let artifact = run.save_preflight_outputs("2026-03-16T12:00:00Z").unwrap();

    let preflight: PreflightArtifact = read_json_typed(&layout.preflight_artifact_path()).unwrap();
    assert_prepared_suite_summary(&artifact);
    assert_prepared_suite_files(&layout);
    assert_eq!(preflight.tools.items[0].name, "kubectl-validate");
    assert_eq!(
        preflight.prepared_suite_path.as_deref(),
        Some("prepared-suite.json")
    );
}

#[test]
fn record_preflight_complete_advances_runner_state() {
    let dir = tempfile::tempdir().unwrap();
    let suite_path = write_suite(dir.path());
    let layout = RunLayout::from_run_dir(&dir.path().join("runs").join("run-2"));
    write_run(&layout, &suite_path);
    initialize_runner_state(&layout.run_dir()).unwrap();

    let ctx = RunContext::from_run_dir(&layout.run_dir()).unwrap();
    let run = RunApplication::from_context(ctx);
    run.record_preflight_complete().unwrap();

    let state = read_runner_state(&layout.run_dir()).unwrap().unwrap();
    assert_eq!(state.phase(), RunnerPhase::Execution);
    assert_eq!(state.preflight_status(), PreflightStatus::Complete);
}

#[test]
fn mark_manifest_applied_updates_prepared_suite_artifact() {
    let dir = tempfile::tempdir().unwrap();
    let suite_path = write_suite(dir.path());
    let layout = RunLayout::from_run_dir(&dir.path().join("runs").join("run-3"));
    write_run(&layout, &suite_path);

    let ctx = RunContext::from_run_dir(&layout.run_dir()).unwrap();
    let run = RunApplication::from_context(ctx);
    run.save_preflight_outputs("2026-03-16T12:00:00Z").unwrap();

    let manifest_path = layout
        .run_dir()
        .join("manifests/prepared/groups/g01/01.yaml");
    run.mark_manifest_applied(&manifest_path, "2026-03-16T12:30:00Z", Some("deploy"))
        .unwrap();

    let artifact = PreparedSuiteArtifact::load(&layout.prepared_suite_path())
        .unwrap()
        .unwrap();
    let manifest = artifact
        .manifest_by_prepared_path("manifests/prepared/groups/g01/01.yaml")
        .unwrap();
    assert!(manifest.applied);
    assert_eq!(manifest.applied_at.as_deref(), Some("2026-03-16T12:30:00Z"));
    assert_eq!(manifest.step.as_deref(), Some("deploy"));
}

#[test]
fn service_container_filter_uses_run_id_label() {
    assert_eq!(run_service_filter("run-4"), "label=io.harness.run-id=run-4");
}

#[test]
fn service_container_ports_publish_envoy_admin_probe_port() {
    assert_eq!(service_probe_port(), defaults::ENVOY_ADMIN_PORT);
    assert_eq!(
        service_container_ports(18_080),
        vec![
            ContainerPort::fixed(18_080, 18_080),
            ContainerPort::ephemeral(defaults::ENVOY_ADMIN_PORT),
        ]
    );
}

#[test]
fn list_service_containers_parses_docker_rows() {
    let docker: Arc<dyn ContainerRuntime> = Arc::new(FakeContainerRuntime::new());
    docker
        .run_detached(&ContainerConfig {
            image: "demo:latest".to_string(),
            name: "svc-a".to_string(),
            network: "demo-net".to_string(),
            env: vec![],
            ports: vec![],
            labels: vec![("io.harness.run-id".to_string(), "run-5".to_string())],
            entrypoint: None,
            restart_policy: None,
            extra_args: vec![],
            command: vec![],
        })
        .unwrap();
    docker
        .run_detached(&ContainerConfig {
            image: "demo:latest".to_string(),
            name: "svc-b".to_string(),
            network: "demo-net".to_string(),
            env: vec![],
            ports: vec![],
            labels: vec![("io.harness.run-id".to_string(), "other-run".to_string())],
            entrypoint: None,
            restart_policy: None,
            extra_args: vec![],
            command: vec![],
        })
        .unwrap();

    let rows = read_service_container_rows(docker.as_ref(), &run_service_filter("run-5")).unwrap();

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].name, "svc-a");
    assert_eq!(rows[0].status, "running");
}
