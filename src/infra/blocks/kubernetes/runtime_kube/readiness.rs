use std::thread;
use std::time::{Duration, Instant};

use k8s_openapi::api::apps::v1::Deployment;
use k8s_openapi::api::core::v1::Pod;
use kube::Client;
use kube::api::{Api, ListParams};

use crate::infra::blocks::BlockError;
use crate::infra::exec::RUNTIME;

pub(super) fn pod_ready(pod: &Pod) -> bool {
    pod.status.as_ref().is_some_and(|status| {
        status.conditions.as_ref().is_some_and(|conditions| {
            conditions
                .iter()
                .any(|condition| condition.type_ == "Ready" && condition.status == "True")
        }) || status.container_statuses.as_ref().is_some_and(|statuses| {
            !statuses.is_empty() && statuses.iter().all(|container| container.ready)
        })
    })
}

fn deployment_available(deployment: &Deployment) -> bool {
    deployment
        .status
        .as_ref()
        .and_then(|status| status.conditions.as_ref())
        .is_some_and(|conditions| {
            conditions
                .iter()
                .any(|condition| condition.type_ == "Available" && condition.status == "True")
        })
}

pub(super) fn wait_for_deployments_available(
    client: Client,
    namespace: &str,
    selector: &str,
    timeout: Duration,
) -> Result<(), BlockError> {
    let deployments: Api<Deployment> = Api::namespaced(client, namespace);
    let started = Instant::now();
    while started.elapsed() < timeout {
        let list = RUNTIME
            .block_on(deployments.list(&ListParams::default().labels(selector)))
            .map_err(|error| BlockError::new("kubernetes", "list deployments", error))?;
        if !list.items.is_empty() && list.iter().all(deployment_available) {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(1));
    }
    Err(BlockError::message(
        "kubernetes",
        "wait for deployments",
        format!("deployments with selector `{selector}` were not available in time"),
    ))
}

pub(super) fn wait_for_pods_ready(
    client: Client,
    namespace: &str,
    selector: &str,
    timeout: Duration,
) -> Result<(), BlockError> {
    let pods: Api<Pod> = Api::namespaced(client, namespace);
    let started = Instant::now();
    while started.elapsed() < timeout {
        let list = RUNTIME
            .block_on(pods.list(&ListParams::default().labels(selector)))
            .map_err(|error| BlockError::new("kubernetes", "list pods", error))?;
        if !list.items.is_empty() && list.iter().all(pod_ready) {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(1));
    }
    Err(BlockError::message(
        "kubernetes",
        "wait for pods",
        format!("pods with selector `{selector}` were not ready in time"),
    ))
}
