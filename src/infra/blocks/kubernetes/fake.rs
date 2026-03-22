use std::path::Path;
use std::sync;
use std::time::Duration;

use crate::infra::blocks::{
    BlockError, ExecRequest, KubernetesRuntime, LocalClusterManager, ManifestDiff, PodSnapshot,
};
use crate::infra::exec::CommandResult;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeKubernetesInvocation {
    pub operation: String,
    pub kubeconfig: Option<String>,
    pub args: Vec<String>,
}

pub enum FakeKubernetesResponse {
    Unit(Result<(), BlockError>),
    Pods(Result<Vec<PodSnapshot>, BlockError>),
    Text(Result<String, BlockError>),
    Diff(Result<ManifestDiff, BlockError>),
    Bool(Result<bool, BlockError>),
    NodePort(Result<Option<u16>, BlockError>),
}

pub struct FakeKubernetesRuntime {
    responses: sync::Mutex<Vec<FakeKubernetesResponse>>,
    invocations: sync::Mutex<Vec<FakeKubernetesInvocation>>,
}

impl FakeKubernetesRuntime {
    #[must_use]
    pub fn new(responses: Vec<FakeKubernetesResponse>) -> Self {
        Self {
            responses: sync::Mutex::new(responses),
            invocations: sync::Mutex::new(Vec::new()),
        }
    }

    #[must_use]
    pub fn invocations(&self) -> Vec<FakeKubernetesInvocation> {
        self.invocations.lock().expect("lock poisoned").clone()
    }

    fn record(
        &self,
        operation: &str,
        kubeconfig: Option<&Path>,
        args: Vec<String>,
    ) -> FakeKubernetesResponse {
        self.invocations
            .lock()
            .expect("lock poisoned")
            .push(FakeKubernetesInvocation {
                operation: operation.to_string(),
                kubeconfig: kubeconfig.map(|path| path.to_string_lossy().into_owned()),
                args,
            });
        let mut responses = self.responses.lock().expect("lock poisoned");
        assert!(
            !responses.is_empty(),
            "FakeKubernetesRuntime: no responses left"
        );
        responses.remove(0)
    }

    fn unit(
        &self,
        operation: &str,
        kubeconfig: Option<&Path>,
        args: Vec<String>,
    ) -> Result<(), BlockError> {
        match self.record(operation, kubeconfig, args) {
            FakeKubernetesResponse::Unit(result) => result,
            _ => panic!("FakeKubernetesRuntime: expected unit response"),
        }
    }

    fn text(
        &self,
        operation: &str,
        kubeconfig: Option<&Path>,
        args: Vec<String>,
    ) -> Result<String, BlockError> {
        match self.record(operation, kubeconfig, args) {
            FakeKubernetesResponse::Text(result) => result,
            _ => panic!("FakeKubernetesRuntime: expected text response"),
        }
    }

    fn pods(
        &self,
        operation: &str,
        kubeconfig: Option<&Path>,
        args: Vec<String>,
    ) -> Result<Vec<PodSnapshot>, BlockError> {
        match self.record(operation, kubeconfig, args) {
            FakeKubernetesResponse::Pods(result) => result,
            _ => panic!("FakeKubernetesRuntime: expected pod response"),
        }
    }

    fn diff(
        &self,
        operation: &str,
        kubeconfig: Option<&Path>,
        args: Vec<String>,
    ) -> Result<ManifestDiff, BlockError> {
        match self.record(operation, kubeconfig, args) {
            FakeKubernetesResponse::Diff(result) => result,
            _ => panic!("FakeKubernetesRuntime: expected diff response"),
        }
    }

    fn bool(
        &self,
        operation: &str,
        kubeconfig: Option<&Path>,
        args: Vec<String>,
    ) -> Result<bool, BlockError> {
        match self.record(operation, kubeconfig, args) {
            FakeKubernetesResponse::Bool(result) => result,
            _ => panic!("FakeKubernetesRuntime: expected bool response"),
        }
    }

    fn node_port(
        &self,
        operation: &str,
        kubeconfig: Option<&Path>,
        args: Vec<String>,
    ) -> Result<Option<u16>, BlockError> {
        match self.record(operation, kubeconfig, args) {
            FakeKubernetesResponse::NodePort(result) => result,
            _ => panic!("FakeKubernetesRuntime: expected nodePort response"),
        }
    }
}

impl KubernetesRuntime for FakeKubernetesRuntime {
    fn list_pods(&self, kubeconfig: Option<&Path>) -> Result<Vec<PodSnapshot>, BlockError> {
        self.pods("list_pods", kubeconfig, vec![])
    }

    fn rollout_restart(
        &self,
        kubeconfig: Option<&Path>,
        namespaces: &[String],
    ) -> Result<(), BlockError> {
        if namespaces.is_empty() {
            self.invocations
                .lock()
                .expect("lock poisoned")
                .push(FakeKubernetesInvocation {
                    operation: "rollout_restart".to_string(),
                    kubeconfig: kubeconfig.map(|path| path.to_string_lossy().into_owned()),
                    args: vec![],
                });
            return Ok(());
        }
        self.unit("rollout_restart", kubeconfig, namespaces.to_vec())
    }

    fn exec(&self, request: &ExecRequest<'_>) -> Result<String, BlockError> {
        self.text(
            "exec",
            request.kubeconfig,
            std::iter::once(request.namespace.to_string())
                .chain(std::iter::once(request.workload.to_string()))
                .chain(request.container.into_iter().map(str::to_string))
                .chain(request.command.iter().map(|arg| (*arg).to_string()))
                .collect(),
        )
    }

    fn apply_manifest(&self, kubeconfig: Option<&Path>, manifest: &Path) -> Result<(), BlockError> {
        self.unit(
            "apply_manifest",
            kubeconfig,
            vec![manifest.to_string_lossy().into_owned()],
        )
    }

    fn dry_run_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<(), BlockError> {
        self.unit(
            "dry_run_manifest",
            kubeconfig,
            vec![manifest.to_string_lossy().into_owned()],
        )
    }

    fn diff_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<ManifestDiff, BlockError> {
        self.diff(
            "diff_manifest",
            kubeconfig,
            vec![manifest.to_string_lossy().into_owned()],
        )
    }

    fn delete_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
        ok_not_found: bool,
    ) -> Result<(), BlockError> {
        self.unit(
            "delete_manifest",
            kubeconfig,
            vec![
                manifest.to_string_lossy().into_owned(),
                ok_not_found.to_string(),
            ],
        )
    }

    fn validate_resources(
        &self,
        kubeconfig: Option<&Path>,
        resources: &[(String, String)],
    ) -> Result<(), BlockError> {
        self.unit(
            "validate_resources",
            kubeconfig,
            resources
                .iter()
                .map(|(kind, api_version)| format!("{kind}:{api_version}"))
                .collect(),
        )
    }

    fn flatten_kubeconfig(
        &self,
        kubeconfig: &Path,
        context: Option<&str>,
    ) -> Result<String, BlockError> {
        self.text(
            "flatten_kubeconfig",
            Some(kubeconfig),
            context.into_iter().map(str::to_string).collect(),
        )
    }

    fn probe_cluster(&self, kubeconfig: &Path) -> Result<(), BlockError> {
        self.unit("probe_cluster", Some(kubeconfig), vec![])
    }

    fn cluster_server(&self, kubeconfig: &Path) -> Result<String, BlockError> {
        self.text("cluster_server", Some(kubeconfig), vec![])
    }

    fn namespace_exists(&self, kubeconfig: &Path, namespace: &str) -> Result<bool, BlockError> {
        self.bool(
            "namespace_exists",
            Some(kubeconfig),
            vec![namespace.to_string()],
        )
    }

    fn crd_exists(&self, kubeconfig: Option<&Path>, name: &str) -> Result<bool, BlockError> {
        self.bool("crd_exists", kubeconfig, vec![name.to_string()])
    }

    fn service_node_port(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        service: &str,
        port_name: &str,
    ) -> Result<Option<u16>, BlockError> {
        self.node_port(
            "service_node_port",
            Some(kubeconfig),
            vec![
                namespace.to_string(),
                service.to_string(),
                port_name.to_string(),
            ],
        )
    }

    fn resource_exists(
        &self,
        kubeconfig: &Path,
        namespace: Option<&str>,
        api_version: &str,
        kind: &str,
        name: &str,
    ) -> Result<bool, BlockError> {
        self.bool(
            "resource_exists",
            Some(kubeconfig),
            namespace
                .into_iter()
                .map(str::to_string)
                .chain([api_version.to_string(), kind.to_string(), name.to_string()])
                .collect(),
        )
    }

    fn delete_namespace(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        wait: bool,
        ok_not_found: bool,
    ) -> Result<(), BlockError> {
        self.unit(
            "delete_namespace",
            Some(kubeconfig),
            vec![
                namespace.to_string(),
                wait.to_string(),
                ok_not_found.to_string(),
            ],
        )
    }

    fn wait_for_deployments_available(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: Duration,
    ) -> Result<(), BlockError> {
        self.unit(
            "wait_for_deployments_available",
            Some(kubeconfig),
            vec![
                namespace.to_string(),
                selector.to_string(),
                timeout.as_secs().to_string(),
            ],
        )
    }

    fn wait_for_pods_ready(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: Duration,
    ) -> Result<(), BlockError> {
        self.unit(
            "wait_for_pods_ready",
            Some(kubeconfig),
            vec![
                namespace.to_string(),
                selector.to_string(),
                timeout.as_secs().to_string(),
            ],
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeK3dInvocation {
    pub args: Vec<String>,
}

pub struct FakeLocalClusterManager {
    responses: sync::Mutex<Vec<Result<CommandResult, BlockError>>>,
    invocations: sync::Mutex<Vec<FakeK3dInvocation>>,
}

impl FakeLocalClusterManager {
    #[must_use]
    pub fn new(responses: Vec<Result<CommandResult, BlockError>>) -> Self {
        Self {
            responses: sync::Mutex::new(responses),
            invocations: sync::Mutex::new(Vec::new()),
        }
    }

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
