use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::infra::blocks::BlockError;

mod backend;
mod diff;
mod dynamic;
mod kubeconfig;
mod local_cluster;
mod pods;
mod runtime_cli;
mod runtime_kube;

pub const KUBERNETES_RUNTIME_ENV: &str = "HARNESS_KUBERNETES_RUNTIME";

pub use backend::{
    KubernetesRuntimeBackend, SelectedKubernetesBackends, kubernetes_backend_from_env,
    kubernetes_backends_from_env, kubernetes_runtime_from_env,
};
#[cfg(feature = "k3d")]
pub use local_cluster::K3dClusterManager;
pub use local_cluster::LocalClusterManager;
pub use runtime_cli::KubectlRuntime;
pub use runtime_kube::KubeRuntime;

/// Snapshot of a Kubernetes pod.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PodSnapshot {
    pub namespace: Option<String>,
    pub name: Option<String>,
    pub ready: Option<String>,
    pub status: Option<String>,
    pub restarts: Option<i64>,
    pub node: Option<String>,
}

/// Result of comparing a manifest to live cluster state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManifestDiff {
    NoDiff,
    HasDiff,
}

/// Parameters for executing a command inside a Kubernetes workload.
pub struct ExecRequest<'a> {
    pub kubeconfig: Option<&'a Path>,
    pub namespace: &'a str,
    pub workload: &'a str,
    pub container: Option<&'a str>,
    pub command: &'a [&'a str],
}

/// Centralized Kubernetes operations for Harness.
pub trait KubernetesRuntime: Send + Sync {
    /// List pod snapshots across all namespaces.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the backend query fails.
    fn list_pods(&self, kubeconfig: Option<&Path>) -> Result<Vec<PodSnapshot>, BlockError>;

    /// Restart deployments in the given namespaces.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if any restart operation fails.
    fn rollout_restart(
        &self,
        kubeconfig: Option<&Path>,
        namespaces: &[String],
    ) -> Result<(), BlockError>;

    /// Run a command in a workload and return stdout.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if pod resolution or command execution fails.
    fn exec(&self, request: &ExecRequest<'_>) -> Result<String, BlockError>;

    /// Apply the manifest to the cluster.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the apply fails.
    fn apply_manifest(&self, kubeconfig: Option<&Path>, manifest: &Path) -> Result<(), BlockError>;

    /// Validate the manifest with a server-side dry-run apply.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the dry-run fails.
    fn dry_run_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<(), BlockError>;

    /// Compare the manifest against live cluster state.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the diff operation fails.
    fn diff_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<ManifestDiff, BlockError>;

    /// Delete all resources described by the manifest.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when any delete operation fails.
    fn delete_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
        ok_not_found: bool,
    ) -> Result<(), BlockError>;

    /// Confirm that the referenced resource kinds exist on the cluster.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when discovery fails or a kind is missing.
    fn validate_resources(
        &self,
        kubeconfig: Option<&Path>,
        resources: &[(String, String)],
    ) -> Result<(), BlockError>;

    /// Flatten a kubeconfig into a single selected context.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the kubeconfig cannot be loaded or serialized.
    fn flatten_kubeconfig(
        &self,
        kubeconfig: &Path,
        context: Option<&str>,
    ) -> Result<String, BlockError>;

    /// Probe cluster reachability.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the API server cannot be reached.
    fn probe_cluster(&self, kubeconfig: &Path) -> Result<(), BlockError>;

    /// Return the configured API server URL for the kubeconfig.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the server cannot be resolved.
    fn cluster_server(&self, kubeconfig: &Path) -> Result<String, BlockError>;

    /// Check whether a namespace exists.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the lookup fails.
    fn namespace_exists(&self, kubeconfig: &Path, namespace: &str) -> Result<bool, BlockError>;

    /// Check whether a CRD exists.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the lookup fails.
    fn crd_exists(&self, kubeconfig: Option<&Path>, name: &str) -> Result<bool, BlockError>;

    /// Resolve a service `NodePort` by named service port.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the lookup fails.
    fn service_node_port(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        service: &str,
        port_name: &str,
    ) -> Result<Option<u16>, BlockError>;

    /// Check whether a named resource exists.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when discovery or lookup fails.
    fn resource_exists(
        &self,
        kubeconfig: &Path,
        namespace: Option<&str>,
        api_version: &str,
        kind: &str,
        name: &str,
    ) -> Result<bool, BlockError>;

    /// Delete a namespace.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` when the delete fails.
    fn delete_namespace(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        wait: bool,
        ok_not_found: bool,
    ) -> Result<(), BlockError>;

    /// Wait for deployments matching a selector to become available.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` on timeout or backend failure.
    fn wait_for_deployments_available(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: Duration,
    ) -> Result<(), BlockError>;

    /// Wait for pods matching a selector to become ready.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` on timeout or backend failure.
    fn wait_for_pods_ready(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: Duration,
    ) -> Result<(), BlockError>;
}

#[cfg(test)]
#[path = "kubernetes/fake.rs"]
mod fake;
#[cfg(test)]
pub use fake::{
    FakeK3dInvocation, FakeKubernetesInvocation, FakeKubernetesRuntime, FakeLocalClusterManager,
};

#[cfg(test)]
#[path = "kubernetes/tests.rs"]
mod tests;
