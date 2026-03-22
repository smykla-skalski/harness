mod cluster_health;
mod recording;
pub(crate) mod reporting;
pub(crate) mod service_lifecycle;
mod status;
mod task_output;

use std::borrow::Cow;
use std::fmt;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{ContainerRuntime, KubernetesRuntime};
use crate::infra::exec::{self, HttpMethod};
use crate::kernel::topology::ClusterSpec;
use crate::platform::runtime::{ClusterRuntime, ControlPlaneAccess, XdsAccess};
use crate::run::RunStatus;
use crate::run::application::dependencies::RunDependencies;
use crate::run::context::{RunContext, RunLayout, RunMetadata};

pub use cluster_health::{ClusterHealthReport, ClusterMemberHealthRecord};
pub use recording::RecordCommandRequest;
pub use service_lifecycle::StartServiceRequest;
pub use status::{ClusterMemberStatusRecord, ClusterStatusReport, ServiceStatusRecord};
pub use task_output::{tail_task_output, wait_for_task_output};

/// Internal helper layer for tracked-run application code.
pub(crate) struct RunServices {
    ctx: RunContext,
    dependencies: RunDependencies,
}

impl fmt::Debug for RunServices {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RunServices")
            .field("ctx", &self.ctx)
            .field("has_docker", &self.dependencies.has_docker())
            .field("has_kubernetes", &self.dependencies.has_kubernetes())
            .finish()
    }
}

impl RunServices {
    /// Build services from a loaded run context.
    ///
    #[must_use]
    pub(crate) fn from_context(ctx: RunContext) -> Self {
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
    pub(crate) fn context(&self) -> &RunContext {
        &self.ctx
    }

    #[must_use]
    pub(crate) fn layout(&self) -> &RunLayout {
        &self.ctx.layout
    }

    #[must_use]
    pub(crate) fn metadata(&self) -> &RunMetadata {
        &self.ctx.metadata
    }

    #[must_use]
    pub(crate) fn status(&self) -> Option<&RunStatus> {
        self.ctx.status.as_ref()
    }

    pub(crate) fn status_mut(&mut self) -> Option<&mut RunStatus> {
        self.ctx.status.as_mut()
    }

    /// Validate suite-declared requirement names against active run support.
    ///
    /// # Errors
    /// Returns `CliError` for unknown or unsupported requirements.
    pub(crate) fn validate_requirement_names(
        &self,
        requirements: &[String],
    ) -> Result<(), CliError> {
        self.dependencies.validate_requirement_names(requirements)
    }

    pub(crate) fn docker(&self) -> Result<&dyn ContainerRuntime, CliError> {
        self.dependencies.docker_required()
    }

    pub(crate) fn docker_if_available(&self) -> Option<&dyn ContainerRuntime> {
        self.dependencies.docker()
    }

    pub(crate) fn kubernetes(&self) -> Result<&dyn KubernetesRuntime, CliError> {
        self.dependencies.kubernetes_required()
    }

    /// Return the persisted cluster spec.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub(crate) fn cluster_spec(&self) -> Result<&ClusterSpec, CliError> {
        self.ctx
            .cluster
            .as_ref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster").into())
    }

    /// Return the runtime adapter for the persisted cluster.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no cluster spec yet.
    pub(crate) fn cluster_runtime(&self) -> Result<ClusterRuntime<'_>, CliError> {
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
    pub(crate) fn resolve_kubeconfig<'a>(
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
    pub(crate) fn control_plane_access(&self) -> Result<ControlPlaneAccess<'_>, CliError> {
        self.cluster_runtime()?.control_plane_access()
    }

    /// Resolve universal XDS access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub(crate) fn xds_access(&self) -> Result<XdsAccess<'_>, CliError> {
        self.cluster_runtime()?.xds_access()
    }

    /// Resolve the universal Docker network.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or no network was recorded.
    pub(crate) fn docker_network(&self) -> Result<&str, CliError> {
        self.cluster_runtime()?.docker_network()
    }

    #[must_use]
    pub(crate) fn resolve_container_name<'a>(&'a self, requested: &'a str) -> Cow<'a, str> {
        self.ctx.cluster.as_ref().map_or_else(
            || Cow::Borrowed(requested),
            |spec| ClusterRuntime::from_spec(spec).resolve_container_name(requested),
        )
    }

    /// Resolve the image used for ad-hoc service containers.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime cannot derive a service image.
    pub(crate) fn service_image<'a>(
        &'a self,
        explicit: Option<&'a str>,
    ) -> Result<Cow<'a, str>, CliError> {
        self.cluster_runtime()?.service_image(explicit)
    }

    /// Call the control-plane API and return the raw response body.
    ///
    /// # Errors
    /// Returns `CliError` when the run has no control-plane endpoint or the request fails.
    pub(crate) fn call_control_plane_text(
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
    pub(crate) fn call_control_plane_json(
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
mod tests;
