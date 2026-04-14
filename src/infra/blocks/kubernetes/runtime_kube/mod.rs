use std::error::Error;
use std::path::Path;

use chrono::Utc;
use k8s_openapi::api::apps::v1::Deployment;
use k8s_openapi::api::core::v1::{Namespace, Pod, Service};
use k8s_openapi::apiextensions_apiserver::pkg::apis::apiextensions::v1::CustomResourceDefinition;
use kube::api::{Api, AttachParams, DeleteParams, DynamicObject, ListParams, Patch, PatchParams};
use kube::discovery::Scope;
use kube::{Client, Error as KubeError};
use serde_json::json;
use tokio::io::AsyncReadExt;

use crate::infra::blocks::BlockError;
use crate::infra::exec::RUNTIME;

use super::diff::normalize_object;
use super::dynamic::{
    discover_resource, json_value, manifest_documents_from_path, resolve_manifest,
};
use super::kubeconfig::flatten_selected_kubeconfig;
use super::{ExecRequest, KubernetesRuntime, ManifestDiff, PodSnapshot};

mod client;
mod readiness;

use client::client_bundle;

/// Production Kubernetes runtime backed by the native `kube` client.
pub struct KubeRuntime;

impl KubeRuntime {
    #[must_use]
    pub const fn new() -> Self {
        Self
    }

    fn resolve_pod_name(
        client: &Client,
        namespace: &str,
        workload: &str,
    ) -> Result<String, BlockError> {
        let Some((kind, name)) = workload.split_once('/') else {
            return Ok(workload.to_string());
        };

        match kind {
            "pod" => Ok(name.to_string()),
            "deploy" | "deployment" => {
                let deployments: Api<Deployment> = Api::namespaced(client.clone(), namespace);
                let deployment = RUNTIME
                    .block_on(deployments.get(name))
                    .map_err(|error| BlockError::new("kubernetes", "get deployment", error))?;
                let selector = deployment
                    .spec
                    .as_ref()
                    .and_then(|spec| spec.selector.match_labels.as_ref())
                    .filter(|labels| !labels.is_empty())
                    .map(|labels| {
                        labels
                            .iter()
                            .map(|(key, value)| format!("{key}={value}"))
                            .collect::<Vec<_>>()
                            .join(",")
                    })
                    .ok_or_else(|| {
                        BlockError::message(
                            "kubernetes",
                            "resolve workload pod",
                            format!("deployment `{name}` does not expose matchLabels"),
                        )
                    })?;
                let pods: Api<Pod> = Api::namespaced(client.clone(), namespace);
                let list = RUNTIME
                    .block_on(pods.list(&ListParams::default().labels(&selector)))
                    .map_err(|error| {
                        BlockError::new("kubernetes", "list deployment pods", error)
                    })?;
                let pods = list.into_iter().collect::<Vec<_>>();
                pods.iter()
                    .find(|pod| readiness::pod_ready(pod))
                    .or_else(|| pods.first())
                    .and_then(|pod| pod.metadata.name.clone())
                    .ok_or_else(|| {
                        BlockError::message(
                            "kubernetes",
                            "resolve workload pod",
                            format!("no pods found for `{workload}`"),
                        )
                    })
            }
            other => Err(BlockError::message(
                "kubernetes",
                "resolve workload pod",
                format!("unsupported workload target `{other}`"),
            )),
        }
    }
}

impl Default for KubeRuntime {
    fn default() -> Self {
        Self::new()
    }
}

impl KubernetesRuntime for KubeRuntime {
    fn list_pods(&self, kubeconfig: Option<&Path>) -> Result<Vec<PodSnapshot>, BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        let pods: Api<Pod> = Api::all(bundle.client);
        let list = RUNTIME
            .block_on(pods.list(&ListParams::default()))
            .map_err(|error| BlockError::new("kubernetes", "list pods", error))?;
        Ok(list
            .into_iter()
            .map(|pod| {
                let (ready_containers, total_containers, restarts) = pod
                    .status
                    .as_ref()
                    .and_then(|status| status.container_statuses.as_ref())
                    .map_or((0_usize, 0_usize, 0_i64), |statuses| {
                        let ready = statuses.iter().filter(|status| status.ready).count();
                        let restarts = statuses
                            .iter()
                            .map(|status| i64::from(status.restart_count))
                            .sum();
                        (ready, statuses.len(), restarts)
                    });

                PodSnapshot {
                    namespace: pod.metadata.namespace,
                    name: pod.metadata.name,
                    ready: Some(format!("{ready_containers}/{total_containers}")),
                    status: pod.status.and_then(|status| status.phase),
                    restarts: Some(restarts),
                    node: pod.spec.and_then(|spec| spec.node_name),
                }
            })
            .collect())
    }

    fn rollout_restart(
        &self,
        kubeconfig: Option<&Path>,
        namespaces: &[String],
    ) -> Result<(), BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        for namespace in namespaces {
            let deployments: Api<Deployment> = Api::namespaced(bundle.client.clone(), namespace);
            let list = RUNTIME
                .block_on(deployments.list(&ListParams::default()))
                .map_err(|error| BlockError::new("kubernetes", "list deployments", error))?;
            for deployment in list {
                let Some(name) = deployment.metadata.name.as_deref() else {
                    continue;
                };
                let patch = json!({
                    "spec": {
                        "template": {
                            "metadata": {
                                "annotations": {
                                    "kubectl.kubernetes.io/restartedAt": Utc::now().to_rfc3339(),
                                }
                            }
                        }
                    }
                });
                RUNTIME
                    .block_on(deployments.patch(
                        name,
                        &PatchParams::default(),
                        &Patch::Merge(&patch),
                    ))
                    .map_err(|error| BlockError::new("kubernetes", "restart deployment", error))?;
            }
        }
        Ok(())
    }

    fn exec(&self, request: &ExecRequest<'_>) -> Result<String, BlockError> {
        let bundle = client_bundle(request.kubeconfig)?;
        let pod_name = Self::resolve_pod_name(&bundle.client, request.namespace, request.workload)?;
        let pods: Api<Pod> = Api::namespaced(bundle.client, request.namespace);
        let mut attach_params = AttachParams::default()
            .stdin(false)
            .stdout(true)
            .stderr(false);
        if let Some(container) = request.container {
            attach_params = attach_params.container(container.to_string());
        }
        let command = request
            .command
            .iter()
            .map(|item| (*item).to_string())
            .collect::<Vec<_>>();
        RUNTIME
            .block_on(async {
                let mut attached = pods.exec(&pod_name, command, &attach_params).await?;
                let mut stdout = String::new();
                if let Some(mut reader) = attached.stdout() {
                    reader.read_to_string(&mut stdout).await?;
                }
                attached.join().await?;
                Ok::<_, Box<dyn Error + Send + Sync>>(stdout)
            })
            .map_err(|error| BlockError::message("kubernetes", "exec workload", error.to_string()))
    }

    fn apply_manifest(&self, kubeconfig: Option<&Path>, manifest: &Path) -> Result<(), BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        let documents = manifest_documents_from_path(manifest)?;
        for document in documents {
            let resolved = resolve_manifest(&bundle.client, &bundle.default_namespace, document)?;
            let api = resolved.api(bundle.client.clone());
            let patch = Patch::Apply(&resolved.document.value);
            let params = PatchParams::apply("harness").force();
            RUNTIME
                .block_on(api.patch(&resolved.document.name, &params, &patch))
                .map_err(|error| BlockError::new("kubernetes", "apply manifest", error))?;
        }
        Ok(())
    }

    fn dry_run_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<(), BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        let documents = manifest_documents_from_path(manifest)?;
        for document in documents {
            let resolved = resolve_manifest(&bundle.client, &bundle.default_namespace, document)?;
            let api = resolved.api(bundle.client.clone());
            let patch = Patch::Apply(&resolved.document.value);
            let params = PatchParams::apply("harness").force().dry_run();
            RUNTIME
                .block_on(api.patch(&resolved.document.name, &params, &patch))
                .map_err(|error| BlockError::new("kubernetes", "dry-run manifest", error))?;
        }
        Ok(())
    }

    fn diff_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
    ) -> Result<ManifestDiff, BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        let documents = manifest_documents_from_path(manifest)?;
        for document in documents {
            let resolved = resolve_manifest(&bundle.client, &bundle.default_namespace, document)?;
            let api = resolved.api(bundle.client.clone());
            let patch = Patch::Apply(&resolved.document.value);
            let params = PatchParams::apply("harness").force().dry_run();
            let dry_run = RUNTIME
                .block_on(api.patch(&resolved.document.name, &params, &patch))
                .map_err(|error| BlockError::new("kubernetes", "dry-run diff manifest", error))?;
            let live = RUNTIME
                .block_on(api.get_opt(&resolved.document.name))
                .map_err(|error| BlockError::new("kubernetes", "get live object", error))?;
            let dry_run_value = normalize_object(json_value(&dry_run, "encode dry-run object")?);
            let Some(live) = live else {
                return Ok(ManifestDiff::HasDiff);
            };
            let live_value = normalize_object(json_value(&live, "encode live object")?);
            if live_value != dry_run_value {
                return Ok(ManifestDiff::HasDiff);
            }
        }
        Ok(ManifestDiff::NoDiff)
    }

    fn delete_manifest(
        &self,
        kubeconfig: Option<&Path>,
        manifest: &Path,
        ok_not_found: bool,
    ) -> Result<(), BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        let documents = manifest_documents_from_path(manifest)?;
        for document in documents {
            let resolved = resolve_manifest(&bundle.client, &bundle.default_namespace, document)?;
            let api = resolved.api(bundle.client.clone());
            let result =
                RUNTIME.block_on(api.delete(&resolved.document.name, &DeleteParams::background()));
            match result {
                Ok(_) => {}
                Err(KubeError::Api(status)) if ok_not_found && status.is_not_found() => {}
                Err(error) => {
                    return Err(BlockError::new("kubernetes", "delete manifest", error));
                }
            }
        }
        Ok(())
    }

    fn validate_resources(
        &self,
        kubeconfig: Option<&Path>,
        resources: &[(String, String)],
    ) -> Result<(), BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        for (kind, api_version) in resources {
            let _ = discover_resource(&bundle.client, api_version, kind)?;
        }
        Ok(())
    }

    fn flatten_kubeconfig(
        &self,
        kubeconfig: &Path,
        context: Option<&str>,
    ) -> Result<String, BlockError> {
        flatten_selected_kubeconfig(kubeconfig, context)
    }

    fn probe_cluster(&self, kubeconfig: &Path) -> Result<(), BlockError> {
        let bundle = client_bundle(Some(kubeconfig))?;
        RUNTIME
            .block_on(bundle.client.apiserver_version())
            .map_err(|error| BlockError::new("kubernetes", "probe cluster", error))?;
        Ok(())
    }

    fn cluster_server(&self, kubeconfig: &Path) -> Result<String, BlockError> {
        Ok(client_bundle(Some(kubeconfig))?.cluster_server)
    }

    fn namespace_exists(&self, kubeconfig: &Path, namespace: &str) -> Result<bool, BlockError> {
        let bundle = client_bundle(Some(kubeconfig))?;
        let namespaces: Api<Namespace> = Api::all(bundle.client);
        RUNTIME
            .block_on(namespaces.get_opt(namespace))
            .map(|namespace| namespace.is_some())
            .map_err(|error| BlockError::new("kubernetes", "get namespace", error))
    }

    fn crd_exists(&self, kubeconfig: Option<&Path>, name: &str) -> Result<bool, BlockError> {
        let bundle = client_bundle(kubeconfig)?;
        let crds: Api<CustomResourceDefinition> = Api::all(bundle.client);
        RUNTIME
            .block_on(crds.get_opt(name))
            .map(|crd| crd.is_some())
            .map_err(|error| BlockError::new("kubernetes", "get crd", error))
    }

    fn service_node_port(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        service: &str,
        port_name: &str,
    ) -> Result<Option<u16>, BlockError> {
        let bundle = client_bundle(Some(kubeconfig))?;
        let services: Api<Service> = Api::namespaced(bundle.client, namespace);
        let service = RUNTIME
            .block_on(services.get(service))
            .map_err(|error| BlockError::new("kubernetes", "get service", error))?;
        Ok(service
            .spec
            .as_ref()
            .and_then(|spec| spec.ports.as_ref())
            .and_then(|ports| {
                ports.iter().find_map(|port| {
                    (port.name.as_deref() == Some(port_name))
                        .then_some(port.node_port)
                        .flatten()
                })
            })
            .and_then(|node_port| u16::try_from(node_port).ok()))
    }

    fn resource_exists(
        &self,
        kubeconfig: &Path,
        namespace: Option<&str>,
        api_version: &str,
        kind: &str,
        name: &str,
    ) -> Result<bool, BlockError> {
        let bundle = client_bundle(Some(kubeconfig))?;
        let (api_resource, scope) = discover_resource(&bundle.client, api_version, kind)?;
        let effective_namespace = match scope {
            Scope::Cluster => None,
            Scope::Namespaced => Some(namespace.unwrap_or(bundle.default_namespace.as_str())),
        };
        let api: Api<DynamicObject> = match effective_namespace {
            Some(namespace) => Api::namespaced_with(bundle.client, namespace, &api_resource),
            None => Api::all_with(bundle.client, &api_resource),
        };
        RUNTIME
            .block_on(api.get_opt(name))
            .map(|resource| resource.is_some())
            .map_err(|error| BlockError::new("kubernetes", "get resource", error))
    }

    fn delete_namespace(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        _wait: bool,
        ok_not_found: bool,
    ) -> Result<(), BlockError> {
        let bundle = client_bundle(Some(kubeconfig))?;
        let namespaces: Api<Namespace> = Api::all(bundle.client);
        let result = RUNTIME.block_on(namespaces.delete(namespace, &DeleteParams::background()));
        match result {
            Ok(_) => Ok(()),
            Err(KubeError::Api(status)) if ok_not_found && status.is_not_found() => Ok(()),
            Err(error) => Err(BlockError::new("kubernetes", "delete namespace", error)),
        }
    }

    fn wait_for_deployments_available(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: std::time::Duration,
    ) -> Result<(), BlockError> {
        let bundle = client_bundle(Some(kubeconfig))?;
        readiness::wait_for_deployments_available(bundle.client, namespace, selector, timeout)
    }

    fn wait_for_pods_ready(
        &self,
        kubeconfig: &Path,
        namespace: &str,
        selector: &str,
        timeout: std::time::Duration,
    ) -> Result<(), BlockError> {
        let bundle = client_bundle(Some(kubeconfig))?;
        readiness::wait_for_pods_ready(bundle.client, namespace, selector, timeout)
    }
}
