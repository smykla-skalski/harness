use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::infra::blocks::BlockError;
use crate::infra::blocks::ProcessExecutor;
use crate::infra::exec::CommandResult;

/// Snapshot of a Kubernetes pod from `kubectl get pods -o json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PodSnapshot {
    pub namespace: Option<String>,
    pub name: Option<String>,
    pub ready: Option<String>,
    pub status: Option<String>,
    pub restarts: Option<i64>,
    pub node: Option<String>,
}

/// Kubernetes cluster operations backed by `kubectl`.
pub trait KubernetesOperator: Send + Sync {
    /// Run `kubectl` with optional kubeconfig, capturing output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the command fails.
    fn run(
        &self,
        kubeconfig: Option<&Path>,
        args: &[&str],
        ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError>;

    /// Restart deployments in the given namespaces.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if any restart command fails.
    fn rollout_restart(
        &self,
        kubeconfig: Option<&Path>,
        namespaces: &[String],
    ) -> Result<(), BlockError>;

    /// List pod snapshots across all namespaces.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the kubectl call or JSON parsing fails.
    fn list_pods(&self, kubeconfig: Option<&Path>) -> Result<Vec<PodSnapshot>, BlockError>;
}

/// Production Kubernetes operator backed by the `kubectl` binary.
pub struct KubectlOperator {
    process: Arc<dyn ProcessExecutor>,
}

impl KubectlOperator {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }

    fn kubectl_args(kubeconfig: Option<&Path>, args: &[&str]) -> Vec<String> {
        let mut command = vec!["kubectl".to_string()];
        if let Some(path) = kubeconfig {
            command.push("--kubeconfig".to_string());
            command.push(path.to_string_lossy().into_owned());
        }
        command.extend(args.iter().map(|arg| (*arg).to_string()));
        command
    }
}

impl KubernetesOperator for KubectlOperator {
    fn run(
        &self,
        kubeconfig: Option<&Path>,
        args: &[&str],
        ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError> {
        let owned = Self::kubectl_args(kubeconfig, args);
        let refs = owned.iter().map(String::as_str).collect::<Vec<_>>();
        self.process.run(&refs, None, None, ok_exit_codes)
    }

    fn rollout_restart(
        &self,
        kubeconfig: Option<&Path>,
        namespaces: &[String],
    ) -> Result<(), BlockError> {
        for namespace in namespaces {
            self.run(
                kubeconfig,
                &["rollout", "restart", "deployment", "-n", namespace],
                &[0],
            )?;
        }
        Ok(())
    }

    fn list_pods(&self, kubeconfig: Option<&Path>) -> Result<Vec<PodSnapshot>, BlockError> {
        let result = self.run(
            kubeconfig,
            &["get", "pods", "--all-namespaces", "-o", "json"],
            &[0],
        )?;
        let value: serde_json::Value = serde_json::from_str(&result.stdout)
            .map_err(|error| BlockError::new("kubernetes", "list_pods parse", error))?;
        let Some(items) = value.get("items").and_then(serde_json::Value::as_array) else {
            return Ok(Vec::new());
        };

        Ok(items
            .iter()
            .map(|item| {
                let namespace = item
                    .get("metadata")
                    .and_then(|v| v.get("namespace"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string);
                let name = item
                    .get("metadata")
                    .and_then(|v| v.get("name"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string);
                let status = item
                    .get("status")
                    .and_then(|v| v.get("phase"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string);
                let node = item
                    .get("spec")
                    .and_then(|v| v.get("nodeName"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string);

                let (ready_containers, total_containers, restarts) = item
                    .get("status")
                    .and_then(|v| v.get("containerStatuses"))
                    .and_then(serde_json::Value::as_array)
                    .map_or((0_usize, 0_usize, 0_i64), |statuses| {
                        let ready = statuses
                            .iter()
                            .filter(|status| {
                                status
                                    .get("ready")
                                    .and_then(serde_json::Value::as_bool)
                                    .unwrap_or(false)
                            })
                            .count();
                        let restarts = statuses
                            .iter()
                            .filter_map(|status| {
                                status
                                    .get("restartCount")
                                    .and_then(serde_json::Value::as_i64)
                            })
                            .sum();
                        (ready, statuses.len(), restarts)
                    });

                PodSnapshot {
                    namespace,
                    name,
                    ready: Some(format!("{ready_containers}/{total_containers}")),
                    status,
                    restarts: Some(restarts),
                    node,
                }
            })
            .collect())
    }
}

/// Local disposable cluster operations backed by `k3d`.
pub trait LocalClusterManager: Send + Sync {
    /// Run `k3d`, capturing output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the command fails.
    fn run(&self, args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, BlockError>;

    /// Check whether a named local cluster exists.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the `k3d` command fails.
    fn cluster_exists(&self, name: &str) -> Result<bool, BlockError>;

    /// Delete or stop a named local cluster.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the operation fails.
    fn stop_cluster(&self, name: &str) -> Result<(), BlockError>;
}

/// Production local-cluster manager backed by `k3d`.
#[cfg(feature = "k3d")]
pub struct K3dClusterManager {
    process: Arc<dyn ProcessExecutor>,
}

#[cfg(feature = "k3d")]
impl K3dClusterManager {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }
}

#[cfg(feature = "k3d")]
impl LocalClusterManager for K3dClusterManager {
    fn run(&self, args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, BlockError> {
        let mut command = vec!["k3d"];
        command.extend_from_slice(args);
        self.process.run(&command, None, None, ok_exit_codes)
    }

    fn cluster_exists(&self, name: &str) -> Result<bool, BlockError> {
        let result = self.run(&["cluster", "list", "--no-headers"], &[0])?;
        Ok(result
            .stdout
            .lines()
            .any(|line| line.split_whitespace().next() == Some(name)))
    }

    fn stop_cluster(&self, name: &str) -> Result<(), BlockError> {
        self.run(&["cluster", "stop", name], &[0])?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "kubernetes/fake.rs"]
mod fake;
#[cfg(test)]
pub use fake::{
    FakeK3dInvocation, FakeKubectlInvocation, FakeKubernetesOperator, FakeLocalClusterManager,
};

#[cfg(test)]
#[path = "kubernetes/tests.rs"]
mod tests;
