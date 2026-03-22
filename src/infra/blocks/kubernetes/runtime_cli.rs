use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use crate::infra::blocks::{BlockError, ProcessExecutor};
use crate::infra::exec::CommandResult;

use super::kubeconfig::flatten_selected_kubeconfig;
use super::{ExecRequest, KubernetesRuntime, ManifestDiff, PodSnapshot, pods};

/// Production Kubernetes runtime backed by `kubectl`.
pub struct KubectlRuntime {
    process: Arc<dyn ProcessExecutor>,
}

impl KubectlRuntime {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }

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

impl KubernetesRuntime for KubectlRuntime {
    fn list_pods(&self, kubeconfig: Option<&Path>) -> Result<Vec<PodSnapshot>, BlockError> {
        let result = self.run(
            kubeconfig,
            &["get", "pods", "--all-namespaces", "-o", "json"],
            &[0],
        )?;
        pods::pod_snapshots_from_json(&result.stdout)
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

    fn exec(&self, request: &ExecRequest<'_>) -> Result<String, BlockError> {
        let mut args = vec![
            "exec".to_string(),
            request.workload.to_string(),
            "-n".to_string(),
            request.namespace.to_string(),
        ];
        if let Some(container) = request.container {
            args.push("-c".to_string());
            args.push(container.to_string());
        }
        args.push("--".to_string());
        args.extend(request.command.iter().map(|arg| (*arg).to_string()));
        let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
        let result = self.run(request.kubeconfig, &refs, &[0])?;
        Ok(result.stdout)
    }

    fn apply_manifest(&self, kubeconfig: Option<&Path>, manifest: &Path) -> Result<(), BlockError> {
        let manifest = manifest.to_string_lossy().into_owned();
        self.run(kubeconfig, &["apply", "-f", &manifest], &[0])?;
        Ok(())
    }

    fn dry_run_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<(), BlockError> {
        let manifest = manifest.to_string_lossy().into_owned();
        self.run(
            kubeconfig,
            &[
                "apply",
                "--server-side",
                "--dry-run=server",
                "-f",
                &manifest,
            ],
            &[0],
        )?;
        Ok(())
    }

    fn diff_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<ManifestDiff, BlockError> {
        let manifest = manifest.to_string_lossy().into_owned();
        let result = self.run(kubeconfig, &["diff", "-f", &manifest], &[0, 1])?;
        Ok(if result.returncode == 0 {
            ManifestDiff::NoDiff
        } else {
            ManifestDiff::HasDiff
        })
    }

    fn delete_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
        ok_not_found: bool,
    ) -> Result<(), BlockError> {
        let manifest = manifest.to_string_lossy().into_owned();
        let ok_exit_codes = if ok_not_found { &[0, 1][..] } else { &[0][..] };
        self.run(kubeconfig, &["delete", "-f", &manifest], ok_exit_codes)?;
        Ok(())
    }

    fn validate_resources(
        &self,
        kubeconfig: Option<&Path>,
        resources: &[(String, String)],
    ) -> Result<(), BlockError> {
        for (kind, api_version) in resources {
            self.run(
                kubeconfig,
                &["explain", kind, "--api-version", api_version],
                &[0],
            )?;
        }
        Ok(())
    }

    fn flatten_kubeconfig(
        &self,
        kubeconfig: &Path,
        context: Option<&str>,
    ) -> Result<String, BlockError> {
        if context.is_none() {
            return flatten_selected_kubeconfig(kubeconfig, None);
        }

        let mut args = vec![
            "config".to_string(),
            "view".to_string(),
            "--raw".to_string(),
            "--flatten".to_string(),
        ];
        if let Some(context) = context {
            args.splice(0..0, ["--context".to_string(), context.to_string()]);
        }
        let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
        let result = self.run(Some(kubeconfig), &refs, &[0])?;
        Ok(result.stdout)
    }

    fn probe_cluster(&self, kubeconfig: &Path) -> Result<(), BlockError> {
        self.run(Some(kubeconfig), &["cluster-info"], &[0])?;
        Ok(())
    }

    fn cluster_server(&self, kubeconfig: &Path) -> Result<String, BlockError> {
        let result = self.run(
            Some(kubeconfig),
            &[
                "config",
                "view",
                "--minify",
                "-o",
                "jsonpath={.clusters[0].cluster.server}",
            ],
            &[0],
        )?;
        Ok(result.stdout.trim().to_string())
    }

    fn namespace_exists(&self, kubeconfig: &Path, namespace: &str) -> Result<bool, BlockError> {
        let result = self.run(Some(kubeconfig), &["get", "namespace", namespace], &[0, 1])?;
        Ok(result.returncode == 0)
    }

    fn crd_exists(&self, kubeconfig: Option<&Path>, name: &str) -> Result<bool, BlockError> {
        let result = self.run(kubeconfig, &["get", "crd", name], &[0, 1])?;
        Ok(result.returncode == 0)
    }

    fn service_node_port(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        service: &str,
        port_name: &str,
    ) -> Result<Option<u16>, BlockError> {
        let jsonpath = format!("jsonpath={{.spec.ports[?(@.name==\"{port_name}\")].nodePort}}");
        let result = self.run(
            Some(kubeconfig),
            &["get", "svc", "-n", namespace, service, "-o", &jsonpath],
            &[0],
        )?;
        let node_port = result.stdout.trim();
        if node_port.is_empty() {
            return Ok(None);
        }
        node_port
            .parse::<u16>()
            .map(Some)
            .map_err(|error| BlockError::new("kubernetes", "parse service nodePort", error))
    }

    fn resource_exists(
        &self,
        kubeconfig: &Path,
        namespace: Option<&str>,
        _api_version: &str,
        kind: &str,
        name: &str,
    ) -> Result<bool, BlockError> {
        let mut args = vec![
            "get".to_string(),
            kind.to_ascii_lowercase(),
            name.to_string(),
        ];
        if let Some(namespace) = namespace {
            args.push("-n".to_string());
            args.push(namespace.to_string());
        }
        let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
        let result = self.run(Some(kubeconfig), &refs, &[0, 1])?;
        Ok(result.returncode == 0)
    }

    fn delete_namespace(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        wait: bool,
        ok_not_found: bool,
    ) -> Result<(), BlockError> {
        let ok_exit_codes = if ok_not_found { &[0, 1][..] } else { &[0][..] };
        if wait {
            self.run(
                Some(kubeconfig),
                &["delete", "namespace", namespace],
                ok_exit_codes,
            )?;
        } else {
            self.run(
                Some(kubeconfig),
                &["delete", "namespace", namespace, "--wait=false"],
                ok_exit_codes,
            )?;
        }
        Ok(())
    }

    fn wait_for_deployments_available(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: Duration,
    ) -> Result<(), BlockError> {
        let timeout = format!("--timeout={}s", timeout.as_secs());
        self.run(
            Some(kubeconfig),
            &[
                "wait",
                &timeout,
                "--namespace",
                namespace,
                "--for",
                "condition=Available",
                "--selector",
                selector,
                "deployments",
            ],
            &[0],
        )?;
        Ok(())
    }

    fn wait_for_pods_ready(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: Duration,
    ) -> Result<(), BlockError> {
        let timeout = format!("--timeout={}s", timeout.as_secs());
        self.run(
            Some(kubeconfig),
            &[
                "wait",
                &timeout,
                "--namespace",
                namespace,
                "--for",
                "condition=Ready",
                "--selector",
                selector,
                "pods",
            ],
            &[0],
        )?;
        Ok(())
    }
}
