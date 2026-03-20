use serde::Deserialize;

use crate::infra::blocks::BlockError;

use super::PodSnapshot;

#[derive(Debug, Deserialize)]
struct PodList {
    items: Vec<PodListItem>,
}

#[derive(Debug, Deserialize)]
struct PodListItem {
    metadata: PodMetadata,
    status: Option<PodStatus>,
    spec: Option<PodSpec>,
}

#[derive(Debug, Deserialize)]
struct PodMetadata {
    namespace: Option<String>,
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PodStatus {
    phase: Option<String>,
    #[serde(rename = "containerStatuses")]
    container_statuses: Option<Vec<ContainerStatus>>,
}

#[derive(Debug, Deserialize)]
struct ContainerStatus {
    ready: Option<bool>,
    #[serde(rename = "restartCount")]
    restart_count: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct PodSpec {
    #[serde(rename = "nodeName")]
    node_name: Option<String>,
}

impl PodListItem {
    fn into_snapshot(self) -> PodSnapshot {
        let (ready_containers, total_containers, restarts) = self
            .status
            .as_ref()
            .and_then(|status| status.container_statuses.as_ref())
            .map_or((0_usize, 0_usize, 0_i64), |statuses| {
                let ready = statuses
                    .iter()
                    .filter(|status| status.ready.unwrap_or(false))
                    .count();
                let restarts = statuses
                    .iter()
                    .filter_map(|status| status.restart_count)
                    .sum();
                (ready, statuses.len(), restarts)
            });

        PodSnapshot {
            namespace: self.metadata.namespace,
            name: self.metadata.name,
            ready: Some(format!("{ready_containers}/{total_containers}")),
            status: self.status.and_then(|status| status.phase),
            restarts: Some(restarts),
            node: self.spec.and_then(|spec| spec.node_name),
        }
    }
}

pub(crate) fn pod_snapshots_from_json(text: &str) -> Result<Vec<PodSnapshot>, BlockError> {
    let list: PodList = serde_json::from_str(text)
        .map_err(|error| BlockError::new("kubernetes", "list_pods parse", error))?;
    Ok(list
        .items
        .into_iter()
        .map(PodListItem::into_snapshot)
        .collect())
}
