mod cluster_health;
mod recording;
pub(crate) mod reporting;
pub(crate) mod service_lifecycle;
mod status;
mod task_output;

use std::borrow::Cow;
use std::fmt;
use std::path::Path;
#[cfg(test)]
use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::ContainerRuntime;
use crate::infra::exec::{self, HttpMethod};
use crate::platform::cluster::ClusterSpec;
use crate::platform::runtime::{ClusterRuntime, ControlPlaneAccess, XdsAccess};
use crate::run::RunStatus;
use crate::run::application::dependencies::RunDependencies;
use crate::run::context::{RunContext, RunLayout, RunMetadata};

pub use cluster_health::{ClusterHealthReport, ClusterMemberHealthRecord};
pub use recording::RecordCommandRequest;
pub use service_lifecycle::StartServiceRequest;
pub use status::{ClusterMemberStatusRecord, ClusterStatusReport, ServiceStatusRecord};
pub use task_output::{tail_task_output, wait_for_task_output};

/// Domain access layer for a tracked run.
pub struct RunServices {
    ctx: RunContext,
    dependencies: RunDependencies,
}

impl fmt::Debug for RunServices {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RunServices")
            .field("ctx", &self.ctx)
            .field("has_docker", &self.dependencies.has_docker())
            .finish()
    }
}

impl RunServices {
    /// Build services from a loaded run context.
    ///
    #[must_use]
    pub fn from_context(ctx: RunContext) -> Self {
        Self::from_context_with_dependencies(ctx, RunDependencies::production())
    }

    /// Build services from a loaded run context using the provided dependencies.
    ///
    pub(crate) fn from_context_with_dependencies(
        ctx: RunContext,
        dependencies: RunDependencies,
    ) -> Self {
        Self::with_dependencies(ctx, dependencies)
    }

    fn with_dependencies(ctx: RunContext, dependencies: RunDependencies) -> Self {
        Self { ctx, dependencies }
    }

    #[must_use]
    pub fn context(&self) -> &RunContext {
        &self.ctx
    }

    #[must_use]
    pub fn layout(&self) -> &RunLayout {
        &self.ctx.layout
    }

    #[must_use]
    pub fn metadata(&self) -> &RunMetadata {
        &self.ctx.metadata
    }

    #[must_use]
    pub fn status(&self) -> Option<&RunStatus> {
        self.ctx.status.as_ref()
    }

    pub fn status_mut(&mut self) -> Option<&mut RunStatus> {
        self.ctx.status.as_mut()
    }

    /// Validate suite-declared requirement names against active run support.
    ///
    /// # Errors
    /// Returns `CliError` for unknown or unsupported requirements.
    pub fn validate_requirement_names(&self, requirements: &[String]) -> Result<(), CliError> {
        self.dependencies.validate_requirement_names(requirements)
    }

    pub(crate) fn docker(&self) -> Result<&dyn ContainerRuntime, CliError> {
        self.dependencies.docker_required()
    }

    pub(crate) fn docker_if_available(&self) -> Option<&dyn ContainerRuntime> {
        self.dependencies.docker()
    }

    /// Return the persisted cluster spec.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub fn cluster_spec(&self) -> Result<&ClusterSpec, CliError> {
        self.ctx
            .cluster
            .as_ref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster").into())
    }

    /// Return the runtime adapter for the persisted cluster.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub fn cluster_runtime(&self) -> Result<ClusterRuntime<'_>, CliError> {
        self.ctx
            .cluster
            .as_ref()
            .map(ClusterRuntime::from_spec)
            .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster").into())
    }

    /// Resolve a kubeconfig path for Kubernetes runs.
    ///
    /// # Errors
    /// Returns `CliError` when no kubeconfig can be determined.
    pub fn resolve_kubeconfig<'a>(
        &'a self,
        explicit: Option<&'a str>,
        cluster: Option<&str>,
    ) -> Result<Cow<'a, Path>, CliError> {
        self.cluster_runtime()?
            .resolve_kubeconfig(explicit, cluster)
    }

    /// Resolve universal control-plane access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub fn control_plane_access(&self) -> Result<ControlPlaneAccess<'_>, CliError> {
        self.cluster_runtime()?.control_plane_access()
    }

    /// Resolve universal XDS access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub fn xds_access(&self) -> Result<XdsAccess<'_>, CliError> {
        self.cluster_runtime()?.xds_access()
    }

    /// Resolve the universal Docker network.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or no network was recorded.
    pub fn docker_network(&self) -> Result<&str, CliError> {
        self.cluster_runtime()?.docker_network()
    }

    #[must_use]
    pub fn resolve_container_name<'a>(&'a self, requested: &'a str) -> Cow<'a, str> {
        self.ctx.cluster.as_ref().map_or_else(
            || Cow::Borrowed(requested),
            |spec| ClusterRuntime::from_spec(spec).resolve_container_name(requested),
        )
    }

    /// Resolve the image used for ad-hoc service containers.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime cannot derive a service image.
    pub fn service_image<'a>(
        &'a self,
        explicit: Option<&'a str>,
    ) -> Result<Cow<'a, str>, CliError> {
        self.cluster_runtime()?.service_image(explicit)
    }

    /// Call the control-plane API and return the raw response body.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no control-plane endpoint or the request fails.
    pub fn call_control_plane_text(
        &self,
        path: &str,
        method: HttpMethod,
        body: Option<&serde_json::Value>,
    ) -> Result<String, CliError> {
        let access = self.control_plane_access()?;
        exec::cp_api_text(access.addr.as_ref(), path, method, body, access.admin_token)
    }

    /// Call the control-plane API and parse the JSON response.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no control-plane endpoint or the request fails.
    pub fn call_control_plane_json(
        &self,
        path: &str,
        method: HttpMethod,
        body: Option<&serde_json::Value>,
    ) -> Result<serde_json::Value, CliError> {
        let access = self.control_plane_access()?;
        exec::cp_api_json(access.addr.as_ref(), path, method, body, access.admin_token)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths, clippy::cognitive_complexity)]

    use std::fs;
    use std::sync::Arc;

    use super::*;
    use crate::infra::io::read_json_typed;
    use crate::run::application::RunApplication;
    use crate::run::context::{PreflightArtifact, RunLayout};
    use crate::run::services::service_lifecycle::{
        read_service_container_rows, run_service_filter,
    };
    use crate::run::workflow::{PreflightStatus, RunnerPhase, initialize_runner_state};
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

    #[test]
    fn save_preflight_outputs_materializes_artifacts() {
        let dir = tempfile::tempdir().unwrap();
        let suite_path = write_suite(dir.path());
        let layout = RunLayout::from_run_dir(&dir.path().join("runs").join("run-1"));
        write_run(&layout, &suite_path);

        let ctx = RunContext::from_run_dir(&layout.run_dir()).unwrap();
        let run = RunApplication::from_context(ctx);
        let artifact = run.save_preflight_outputs("2026-03-16T12:00:00Z").unwrap();

        assert_eq!(artifact.baselines.len(), 1);
        assert_eq!(artifact.groups.len(), 1);
        assert_eq!(artifact.groups[0].manifests.len(), 2);
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

        let preflight: PreflightArtifact =
            read_json_typed(&layout.preflight_artifact_path()).unwrap();
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

        let state = crate::run::workflow::read_runner_state(&layout.run_dir())
            .unwrap()
            .unwrap();
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
    fn list_service_containers_parses_docker_rows() {
        let docker: Arc<dyn ContainerRuntime> =
            Arc::new(crate::infra::blocks::FakeContainerRuntime::new());
        docker
            .run_detached(&crate::infra::blocks::ContainerConfig {
                image: "demo:latest".to_string(),
                name: "svc-a".to_string(),
                network: "demo-net".to_string(),
                env: vec![],
                ports: vec![],
                labels: vec![("io.harness.run-id".to_string(), "run-5".to_string())],
                extra_args: vec![],
                command: vec![],
            })
            .unwrap();
        docker
            .run_detached(&crate::infra::blocks::ContainerConfig {
                image: "demo:latest".to_string(),
                name: "svc-b".to_string(),
                network: "demo-net".to_string(),
                env: vec![],
                ports: vec![],
                labels: vec![("io.harness.run-id".to_string(), "other-run".to_string())],
                extra_args: vec![],
                command: vec![],
            })
            .unwrap();

        let rows =
            read_service_container_rows(docker.as_ref(), &run_service_filter("run-5")).unwrap();

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "svc-a");
        assert_eq!(rows[0].status, "running");
    }
}
