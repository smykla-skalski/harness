use std::path::Path;
use std::sync;

use crate::infra::blocks::{BlockError, KubernetesOperator, LocalClusterManager, PodSnapshot};
use crate::infra::exec::CommandResult;

use super::pods::pod_snapshots_from_json;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeKubectlInvocation {
    pub kubeconfig: Option<String>,
    pub args: Vec<String>,
}

pub struct FakeKubernetesOperator {
    responses: sync::Mutex<Vec<Result<CommandResult, BlockError>>>,
    invocations: sync::Mutex<Vec<FakeKubectlInvocation>>,
}

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
        pod_snapshots_from_json(&result.stdout)
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
