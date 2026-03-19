use std::borrow::Cow;
use std::fmt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::BlockRegistry;
use crate::infra::exec::{CommandResult, HttpMethod};
use crate::infra::io::write_json_pretty;
use crate::platform::cluster::ClusterSpec;
use crate::platform::runtime::{ClusterRuntime, ControlPlaneAccess, XdsAccess};
use crate::run::context::{RunContext, RunLayout, RunMetadata, RunRepository};
use crate::run::services::{
    ClusterHealthReport, ClusterStatusReport, RunServices, ServiceStatusRecord,
};
use crate::run::{PreparedSuiteArtifact, PreparedSuitePlan, RunStatus, SuiteSpec};

/// Application boundary for tracked-run use cases.
pub struct RunApplication {
    services: RunServices,
}

impl fmt::Debug for RunApplication {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RunApplication")
            .field("services", &self.services)
            .finish()
    }
}

impl RunApplication {
    /// Return the active tracked run directory when one is selected.
    ///
    /// # Errors
    /// Returns `CliError` when the current-run pointer cannot be loaded.
    pub fn current_run_dir() -> Result<Option<PathBuf>, CliError> {
        let repo = RunRepository;
        Ok(repo
            .load_current_pointer()?
            .map(|pointer| pointer.layout.run_dir()))
    }

    /// Clear the active current-run pointer.
    ///
    /// # Errors
    /// Returns `CliError` when pointer persistence fails.
    pub fn clear_current_pointer() -> Result<(), CliError> {
        let repo = RunRepository;
        repo.clear_current_pointer()
    }

    /// Load the persisted cluster spec from the active current-run pointer.
    ///
    /// # Errors
    /// Returns `CliError` when the pointer cannot be loaded.
    pub fn load_current_cluster_spec() -> Result<Option<ClusterSpec>, CliError> {
        let repo = RunRepository;
        Ok(repo
            .load_current_pointer()?
            .and_then(|pointer| pointer.cluster))
    }

    /// Persist a cluster spec into run-owned state for the active tracked run.
    ///
    /// # Errors
    /// Returns `CliError` when pointer or state persistence fails.
    pub fn persist_current_cluster_spec(spec: &ClusterSpec) -> Result<(), CliError> {
        let repo = RunRepository;
        if let Some(pointer) = repo.load_current_pointer()? {
            let run_dir = pointer.layout.run_dir();
            let _ = repo.update_current_pointer(|record| {
                record.cluster = Some(spec.clone());
            })?;

            let state_dir = run_dir.join("state");
            if state_dir.is_dir() {
                let cluster_path = state_dir.join("cluster.json");
                write_json_pretty(&cluster_path, spec)?;
            }
        }
        Ok(())
    }

    /// Build the application boundary from a loaded run context.
    ///
    #[must_use]
    pub fn from_context(ctx: RunContext) -> Self {
        Self {
            services: RunServices::from_context_with_blocks(
                ctx,
                Arc::new(BlockRegistry::production()),
            ),
        }
    }

    /// Build the application boundary from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if the run context cannot be loaded.
    pub fn from_run_dir(run_dir: &Path) -> Result<Self, CliError> {
        Ok(Self::from_context(RunContext::from_run_dir(run_dir)?))
    }

    /// Build the application boundary from the current session run pointer.
    ///
    /// # Errors
    /// Returns `CliError` if the pointer or referenced run is invalid.
    pub fn from_current() -> Result<Option<Self>, CliError> {
        Ok(RunContext::from_current()?.map(Self::from_context))
    }

    #[must_use]
    pub fn context(&self) -> &RunContext {
        self.services.context()
    }

    #[must_use]
    pub fn layout(&self) -> &RunLayout {
        self.services.layout()
    }

    #[must_use]
    pub fn metadata(&self) -> &RunMetadata {
        self.services.metadata()
    }

    #[must_use]
    pub fn status(&self) -> Option<&RunStatus> {
        self.services.status()
    }

    pub fn status_mut(&mut self) -> Option<&mut RunStatus> {
        self.services.status_mut()
    }

    /// Return the persisted cluster spec.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub fn cluster_spec(&self) -> Result<&ClusterSpec, CliError> {
        self.services.cluster_spec()
    }

    /// Return the runtime adapter for the persisted cluster.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub fn cluster_runtime(&self) -> Result<ClusterRuntime<'_>, CliError> {
        self.services.cluster_runtime()
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
        self.services.resolve_kubeconfig(explicit, cluster)
    }

    /// Resolve universal control-plane access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub fn control_plane_access(&self) -> Result<ControlPlaneAccess<'_>, CliError> {
        self.services.control_plane_access()
    }

    /// Resolve universal XDS access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub fn xds_access(&self) -> Result<XdsAccess<'_>, CliError> {
        self.services.xds_access()
    }

    /// Resolve the universal Docker network.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or no network was recorded.
    pub fn docker_network(&self) -> Result<&str, CliError> {
        self.services.docker_network()
    }

    #[must_use]
    pub fn resolve_container_name<'a>(&'a self, requested: &'a str) -> Cow<'a, str> {
        self.services.resolve_container_name(requested)
    }

    /// Resolve the image used for ad-hoc service containers.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime cannot derive a service image.
    pub fn service_image<'a>(
        &'a self,
        explicit: Option<&'a str>,
    ) -> Result<Cow<'a, str>, CliError> {
        self.services.service_image(explicit)
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
        self.services.call_control_plane_text(path, method, body)
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
        self.services.call_control_plane_json(path, method, body)
    }

    /// Load the suite specification referenced by the run metadata.
    ///
    /// # Errors
    /// Returns `CliError` if the suite markdown cannot be loaded.
    pub fn suite_spec(&self) -> Result<SuiteSpec, CliError> {
        self.services.suite_spec()
    }

    /// Build the preflight materialization plan for this run.
    ///
    /// # Errors
    /// Returns `CliError` if the suite cannot be loaded or parsed.
    pub fn build_preflight_plan(&self, checked_at: &str) -> Result<PreparedSuitePlan, CliError> {
        self.services.build_preflight_plan(checked_at)
    }

    /// Materialize prepared-suite and preflight artifacts to disk.
    ///
    /// # Errors
    /// Returns `CliError` on parse or IO failures.
    pub fn save_preflight_outputs(
        &self,
        checked_at: &str,
    ) -> Result<PreparedSuiteArtifact, CliError> {
        self.services.save_preflight_outputs(checked_at)
    }

    /// Validate that the run metadata only references registered requirement names.
    ///
    /// # Errors
    /// Returns `CliError` when any requirement name is unknown.
    pub fn validate_requirement_names(&self) -> Result<(), CliError> {
        Ok(self
            .services
            .blocks()
            .validate_requirement_names(&self.metadata().requires)?)
    }

    /// Capture the current cluster state, persist it, and update the run status.
    ///
    /// # Errors
    /// Returns `CliError` on capture or persistence failures.
    pub fn capture_state(
        &mut self,
        label: &str,
        kubeconfig: Option<&str>,
    ) -> Result<String, CliError> {
        self.services.capture_state(label, kubeconfig)
    }

    /// Mark a prepared manifest as applied when it belongs to the tracked run.
    ///
    /// # Errors
    /// Returns `CliError` on prepared-suite load/save failures.
    pub fn mark_manifest_applied(
        &self,
        manifest_path: &Path,
        applied_at: &str,
        step: Option<&str>,
    ) -> Result<(), CliError> {
        self.services
            .mark_manifest_applied(manifest_path, applied_at, step)
    }

    /// Advance the runner workflow to completed preflight when applicable.
    ///
    /// # Errors
    /// Returns `CliError` on workflow persistence failures.
    pub fn record_preflight_complete(&self) -> Result<(), CliError> {
        self.services.record_preflight_complete()
    }

    /// Check current cluster member health.
    ///
    /// # Errors
    /// Returns `CliError` on runtime inspection failures.
    pub fn cluster_health_report(&self) -> Result<ClusterHealthReport<'_>, CliError> {
        self.services.cluster_health_report()
    }

    /// Build the current cluster status report.
    ///
    /// # Errors
    /// Returns `CliError` on runtime inspection failures.
    pub fn status_report(&self) -> Result<ClusterStatusReport<'_>, CliError> {
        self.services.status_report()
    }

    #[must_use]
    pub fn service_container_filter(&self) -> String {
        self.services.service_container_filter()
    }

    /// List service containers scoped to the current run.
    ///
    /// # Errors
    /// Returns `CliError` on docker invocation failures.
    pub fn list_service_containers(&self) -> Result<Vec<ServiceStatusRecord>, CliError> {
        self.services.list_service_containers()
    }

    /// List all managed service containers without requiring a tracked run.
    ///
    /// # Errors
    /// Returns `CliError` when docker is unavailable or listing fails.
    pub fn list_managed_service_containers() -> Result<Vec<ServiceStatusRecord>, CliError> {
        let blocks = BlockRegistry::production();
        let docker = blocks
            .docker
            .as_deref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("docker"))?;
        let result = docker.list_formatted(
            &["--filter", "label=io.harness.service=true"],
            "{{.Names}}\t{{.Status}}",
        )?;
        Ok(result
            .stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let mut parts = line.splitn(2, '\t');
                ServiceStatusRecord {
                    name: parts.next().unwrap_or_default().to_string(),
                    status: parts.next().unwrap_or_default().to_string(),
                }
            })
            .collect())
    }

    /// Remove a managed service container by name without requiring a tracked run.
    ///
    /// # Errors
    /// Returns `CliError` when docker is unavailable or the removal fails.
    pub fn remove_managed_service_container(name: &str) -> Result<(), CliError> {
        let blocks = BlockRegistry::production();
        let docker = blocks
            .docker
            .as_deref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("docker"))?;
        docker.remove(name)?;
        Ok(())
    }

    /// Start a tracked universal service container and attach a Kuma dataplane.
    ///
    /// # Errors
    /// Returns `CliError` when the tracked run is missing universal access details
    /// or when container setup fails.
    pub fn start_service(&self, request: &StartServiceRequest<'_>) -> Result<(), CliError> {
        self.services.start_service(request)
    }

    /// Read or stream logs for a tracked cluster container.
    ///
    /// Returns `None` when logs are streamed directly to the terminal.
    ///
    /// # Errors
    /// Returns `CliError` on docker invocation failures.
    pub fn service_logs(
        &self,
        name: &str,
        tail: u32,
        follow: bool,
    ) -> Result<Option<CommandResult>, CliError> {
        self.services.service_logs(name, tail, follow)
    }

    /// Finalize a completed group in the tracked run report.
    ///
    /// # Errors
    /// Returns `CliError` on capture, persistence, or status-update failures.
    pub fn finalize_group_report(
        &mut self,
        request: &GroupReportRequest<'_>,
    ) -> Result<(), CliError> {
        self.services.finalize_group_report(request).map(|_| ())
    }
}

pub use crate::run::services::{
    GroupReportRequest, RecordCommandRequest, ReportCheckOutcome, StartServiceRequest,
    check_report_compactness, record_command, tail_task_output, wait_for_task_output,
};
