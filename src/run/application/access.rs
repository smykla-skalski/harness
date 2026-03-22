use std::borrow::Cow;
use std::path::Path;

use crate::errors::CliError;
use crate::infra::blocks::KubernetesRuntime;
use crate::infra::exec::HttpMethod;
use crate::kernel::topology::ClusterSpec;
use crate::platform::runtime::{ClusterRuntime, ControlPlaneAccess, XdsAccess};
use crate::run::RunStatus;
use crate::run::context::{RunContext, RunLayout, RunMetadata};

use super::RunApplication;

impl RunApplication {
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
    pub(crate) fn cluster_runtime(&self) -> Result<ClusterRuntime<'_>, CliError> {
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
    pub(crate) fn control_plane_access(&self) -> Result<ControlPlaneAccess<'_>, CliError> {
        self.services.control_plane_access()
    }

    /// Resolve universal XDS access.
    ///
    /// # Errors
    /// Returns `CliError` when the run is not universal or the endpoint is incomplete.
    pub(crate) fn xds_access(&self) -> Result<XdsAccess<'_>, CliError> {
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

    /// Resolve the configured Kubernetes runtime.
    ///
    /// # Errors
    /// Returns `CliError` when Kubernetes runtime support is unavailable.
    pub fn kubernetes_runtime(&self) -> Result<&dyn KubernetesRuntime, CliError> {
        self.services.kubernetes()
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

    /// Validate that the run metadata only references registered requirement names.
    ///
    /// # Errors
    /// Returns `CliError` when any requirement name is unknown.
    pub fn validate_requirement_names(&self) -> Result<(), CliError> {
        self.services
            .validate_requirement_names(&self.metadata().requires)
    }
}
