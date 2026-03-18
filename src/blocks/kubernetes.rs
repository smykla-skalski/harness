use std::path::Path;
#[cfg(test)]
use std::sync;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::blocks::{BlockError, ContainerRuntime, ProcessExecutor};
use crate::core_defs::CommandResult;

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
pub struct K3dClusterManager {
    process: Arc<dyn ProcessExecutor>,
    #[allow(dead_code)]
    container_runtime: Arc<dyn ContainerRuntime>,
}

impl K3dClusterManager {
    #[must_use]
    pub fn new(
        process: Arc<dyn ProcessExecutor>,
        container_runtime: Arc<dyn ContainerRuntime>,
    ) -> Self {
        Self {
            process,
            container_runtime,
        }
    }
}

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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeKubectlInvocation {
    pub kubeconfig: Option<String>,
    pub args: Vec<String>,
}

#[cfg(test)]
pub struct FakeKubernetesOperator {
    responses: sync::Mutex<Vec<Result<CommandResult, BlockError>>>,
    invocations: sync::Mutex<Vec<FakeKubectlInvocation>>,
}

#[cfg(test)]
impl FakeKubernetesOperator {
    #[must_use]
    pub fn new(responses: Vec<Result<CommandResult, BlockError>>) -> Self {
        Self {
            responses: sync::Mutex::new(responses),
            invocations: sync::Mutex::new(Vec::new()),
        }
    }

    /// Returns recorded invocations.
    ///
    /// # Panics
    /// Panics if the mutex is poisoned.
    #[must_use]
    pub fn invocations(&self) -> Vec<FakeKubectlInvocation> {
        self.invocations.lock().expect("lock poisoned").clone()
    }

    fn next(&self, kubeconfig: Option<&Path>, args: &[&str]) -> Result<CommandResult, BlockError> {
        self.invocations
            .lock()
            .expect("lock poisoned")
            .push(FakeKubectlInvocation {
                kubeconfig: kubeconfig.map(|path| path.to_string_lossy().into_owned()),
                args: args.iter().map(|arg| (*arg).to_string()).collect(),
            });
        let mut responses = self.responses.lock().expect("lock poisoned");
        assert!(
            !responses.is_empty(),
            "FakeKubernetesOperator: no responses left"
        );
        responses.remove(0)
    }
}

#[cfg(test)]
impl KubernetesOperator for FakeKubernetesOperator {
    fn run(
        &self,
        kubeconfig: Option<&Path>,
        args: &[&str],
        _ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError> {
        self.next(kubeconfig, args)
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
            .map(|item| PodSnapshot {
                namespace: item
                    .get("metadata")
                    .and_then(|v| v.get("namespace"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string),
                name: item
                    .get("metadata")
                    .and_then(|v| v.get("name"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string),
                ready: None,
                status: item
                    .get("status")
                    .and_then(|v| v.get("phase"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string),
                restarts: None,
                node: item
                    .get("spec")
                    .and_then(|v| v.get("nodeName"))
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string),
            })
            .collect())
    }
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeK3dInvocation {
    pub args: Vec<String>,
}

#[cfg(test)]
pub struct FakeLocalClusterManager {
    responses: sync::Mutex<Vec<Result<CommandResult, BlockError>>>,
    invocations: sync::Mutex<Vec<FakeK3dInvocation>>,
}

#[cfg(test)]
impl FakeLocalClusterManager {
    #[must_use]
    pub fn new(responses: Vec<Result<CommandResult, BlockError>>) -> Self {
        Self {
            responses: sync::Mutex::new(responses),
            invocations: sync::Mutex::new(Vec::new()),
        }
    }

    /// Returns recorded invocations.
    ///
    /// # Panics
    /// Panics if the mutex is poisoned.
    #[must_use]
    pub fn invocations(&self) -> Vec<FakeK3dInvocation> {
        self.invocations.lock().expect("lock poisoned").clone()
    }

    fn next(&self, args: &[&str]) -> Result<CommandResult, BlockError> {
        self.invocations
            .lock()
            .expect("lock poisoned")
            .push(FakeK3dInvocation {
                args: args.iter().map(|arg| (*arg).to_string()).collect(),
            });
        let mut responses = self.responses.lock().expect("lock poisoned");
        assert!(
            !responses.is_empty(),
            "FakeLocalClusterManager: no responses left"
        );
        responses.remove(0)
    }
}

#[cfg(test)]
impl LocalClusterManager for FakeLocalClusterManager {
    fn run(&self, args: &[&str], _ok_exit_codes: &[i32]) -> Result<CommandResult, BlockError> {
        self.next(args)
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
mod tests {
    use super::*;
    use crate::blocks::{
        FakeContainerRuntime, FakeProcessExecutor, FakeProcessMethod, FakeResponse,
    };
    use std::sync::Arc;

    fn success_result(args: &[&str], stdout: &str) -> CommandResult {
        CommandResult {
            args: args.iter().map(|arg| (*arg).to_string()).collect(),
            returncode: 0,
            stdout: stdout.to_string(),
            stderr: String::new(),
        }
    }

    #[test]
    fn kubectl_operator_includes_kubeconfig() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "kubectl".to_string(),
            expected_args: Some(vec![
                "kubectl".into(),
                "--kubeconfig".into(),
                "/tmp/kubeconfig".into(),
                "get".into(),
                "pods".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["kubectl", "--kubeconfig", "/tmp/kubeconfig", "get", "pods"],
                "",
            )),
        }]));
        let operator = KubectlOperator::new(fake);

        let result = operator
            .run(Some(Path::new("/tmp/kubeconfig")), &["get", "pods"], &[0])
            .expect("expected kubectl run to succeed");

        assert_eq!(result.returncode, 0);
    }

    fn assert_demo_pod(pod: &PodSnapshot) {
        assert_eq!(pod.namespace.as_deref(), Some("default"));
        assert_eq!(pod.name.as_deref(), Some("demo-123"));
        assert_eq!(pod.ready.as_deref(), Some("1/2"));
        assert_eq!(pod.status.as_deref(), Some("Running"));
        assert_eq!(pod.restarts, Some(3));
        assert_eq!(pod.node.as_deref(), Some("node-a"));
    }

    #[test]
    fn kubectl_operator_list_pods_parses_json() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "kubectl".to_string(),
            expected_args: None,
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["kubectl", "get", "pods", "--all-namespaces", "-o", "json"],
                r#"{
                  "items": [
                    {
                      "metadata": { "namespace": "default", "name": "demo-123" },
                      "spec": { "nodeName": "node-a" },
                      "status": {
                        "phase": "Running",
                        "containerStatuses": [
                          { "ready": true, "restartCount": 1 },
                          { "ready": false, "restartCount": 2 }
                        ]
                      }
                    }
                  ]
                }"#,
            )),
        }]));
        let operator = KubectlOperator::new(fake);

        let pods = operator.list_pods(None).expect("expected pod list");
        assert_eq!(pods.len(), 1);
        assert_demo_pod(&pods[0]);
    }

    #[test]
    fn k3d_cluster_manager_detects_existing_cluster() {
        let fake_process = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "k3d".to_string(),
            expected_args: Some(vec![
                "k3d".into(),
                "cluster".into(),
                "list".into(),
                "--no-headers".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["k3d", "cluster", "list", "--no-headers"],
                "demo 1/1 0/0\n",
            )),
        }]));
        let fake_container = Arc::new(FakeContainerRuntime::new());
        let manager = K3dClusterManager::new(fake_process, fake_container);

        let exists = manager
            .cluster_exists("demo")
            .expect("expected cluster_exists to succeed");

        assert!(exists);
    }

    #[test]
    fn fake_kubernetes_operator_records_invocations() {
        let fake =
            FakeKubernetesOperator::new(vec![Ok(success_result(&["kubectl", "get", "pods"], ""))]);

        fake.run(None, &["get", "pods"], &[0])
            .expect("expected success");

        let invocations = fake.invocations();
        assert_eq!(invocations.len(), 1);
        assert_eq!(invocations[0].args, vec!["get", "pods"]);
    }

    #[test]
    fn fake_local_cluster_manager_records_invocations() {
        let fake = FakeLocalClusterManager::new(vec![Ok(success_result(
            &["k3d", "cluster", "stop", "demo"],
            "",
        ))]);

        fake.stop_cluster("demo").expect("expected success");

        let invocations = fake.invocations();
        assert_eq!(invocations.len(), 1);
        assert_eq!(invocations[0].args, vec!["cluster", "stop", "demo"]);
    }

    #[test]
    fn kubernetes_block_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<KubectlOperator>();
        assert_send_sync::<K3dClusterManager>();
        assert_send_sync::<PodSnapshot>();
    }

    // -- Contract tests: fake satisfies the same invariants as production --

    mod contracts {
        use super::*;

        fn contract_rollout_restart_empty_namespaces(
            operator: &dyn KubernetesOperator,
            kubeconfig: Option<&Path>,
        ) {
            operator
                .rollout_restart(kubeconfig, &[])
                .expect("rollout_restart with empty namespaces should be a no-op");
        }

        fn contract_list_pods_returns_list(
            operator: &dyn KubernetesOperator,
            kubeconfig: Option<&Path>,
        ) {
            let pods = operator
                .list_pods(kubeconfig)
                .expect("list_pods should succeed");
            let _ = pods.len();
        }

        #[test]
        fn fake_satisfies_rollout_restart_empty_namespaces() {
            let fake = FakeKubernetesOperator::new(vec![]);
            contract_rollout_restart_empty_namespaces(&fake, None);
        }

        #[test]
        fn fake_satisfies_list_pods_returns_list() {
            let fake = FakeKubernetesOperator::new(vec![Ok(success_result(
                &["kubectl", "get", "pods", "--all-namespaces", "-o", "json"],
                r#"{"items":[]}"#,
            ))]);
            contract_list_pods_returns_list(&fake, None);
        }
    }
}
