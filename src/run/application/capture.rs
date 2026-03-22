use rayon::prelude::*;
use tracing::warn;

use crate::errors::CliError;
use crate::infra::io::write_json_pretty;
use crate::kernel::topology::Platform;
use crate::run::audit::write_run_status_with_audit;
use crate::run::state_capture::{
    DockerContainerSnapshot, KubernetesCaptureSnapshot, KubernetesPodSnapshot,
    StateCaptureSnapshot, UniversalCaptureSnapshot, UniversalDataplaneCollection,
};
use crate::run::workflow::read_runner_state;
use crate::workspace::utc_now;

use super::RunApplication;

impl RunApplication {
    /// Capture the current cluster state, persist it, and update the run status.
    ///
    /// # Errors
    /// Returns `CliError` on capture or persistence failures.
    pub fn capture_state(
        &mut self,
        label: &str,
        kubeconfig: Option<&str>,
    ) -> Result<String, CliError> {
        let timestamp = utc_now().replace(':', "");
        let capture_path = self
            .layout()
            .state_dir()
            .join(format!("{label}-{timestamp}.json"));
        let snapshot = self.build_capture_snapshot(kubeconfig)?;
        write_json_pretty(&capture_path, &snapshot)?;

        let rel = self.layout().relative_path(&capture_path).into_owned();
        let run_dir = self.layout().run_dir();
        if let Some(status) = self.status_mut() {
            status.last_state_capture = Some(rel.clone());
            let runner_state = read_runner_state(&run_dir)?;
            write_run_status_with_audit(&run_dir, status, runner_state.as_ref(), None, None)?;
        }
        Ok(rel)
    }

    fn build_capture_snapshot(
        &self,
        kubeconfig: Option<&str>,
    ) -> Result<StateCaptureSnapshot, CliError> {
        match self.cluster_runtime()?.platform() {
            Platform::Kubernetes => self.capture_kubernetes_snapshot(kubeconfig),
            Platform::Universal => self.capture_universal_snapshot(),
        }
    }

    fn capture_kubernetes_snapshot(
        &self,
        kubeconfig: Option<&str>,
    ) -> Result<StateCaptureSnapshot, CliError> {
        let resolved = self.resolve_kubeconfig(kubeconfig, None)?;
        let pods = self
            .kubernetes_runtime()?
            .list_pods(Some(resolved.as_ref()))?
            .par_iter()
            .map(|pod| KubernetesPodSnapshot {
                namespace: pod.namespace.clone().unwrap_or_default(),
                name: pod.name.clone().unwrap_or_default(),
                phase: pod.status.clone(),
                ready: pod
                    .ready
                    .as_deref()
                    .and_then(|value| value.split_once('/'))
                    .is_some_and(|(ready, total)| ready == total && total != "0"),
            })
            .collect();
        Ok(StateCaptureSnapshot::Kubernetes(
            KubernetesCaptureSnapshot { pods },
        ))
    }

    fn capture_universal_snapshot(&self) -> Result<StateCaptureSnapshot, CliError> {
        let container_rows = self.capture_universal_containers()?;
        let (dataplanes, dataplanes_error) = self.capture_universal_dataplanes();
        Ok(StateCaptureSnapshot::Universal(UniversalCaptureSnapshot {
            containers: container_rows,
            dataplanes,
            dataplanes_error,
        }))
    }

    fn capture_universal_containers(&self) -> Result<Vec<DockerContainerSnapshot>, CliError> {
        let network = self
            .docker_network()
            .ok()
            .map_or_else(|| "harness-default".to_string(), str::to_string);
        let filter = format!("network={network}");
        let containers = self
            .services
            .docker()?
            .list_formatted(&["--filter", &filter], "{{json .}}")?;
        Ok(containers
            .stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .map(|row| DockerContainerSnapshot {
                id: row["ID"].as_str().map(str::to_string),
                image: row["Image"].as_str().map(str::to_string),
                name: row["Names"].as_str().map(str::to_string),
                status: row["Status"].as_str().map(str::to_string),
                networks: row["Networks"].as_str().map(str::to_string),
            })
            .collect())
    }

    fn capture_universal_dataplanes(&self) -> (UniversalDataplaneCollection, Option<String>) {
        self.query_dataplanes("default")
            .inspect_err(|error| warn!(%error, "CP API dataplanes query failed"))
            .map_or_else(
                |error| {
                    (
                        UniversalDataplaneCollection::default(),
                        Some(error.to_string()),
                    )
                },
                |dataplanes| (dataplanes, None),
            )
    }
}
