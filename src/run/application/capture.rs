use rayon::prelude::*;
use tracing::warn;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec;
use crate::infra::io::write_json_pretty;
use crate::platform::cluster::Platform;
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
        let result = exec::kubectl(
            Some(resolved.as_ref()),
            &["get", "pods", "--all-namespaces", "-o", "json"],
            &[0],
        )?;
        let value: serde_json::Value = serde_json::from_str(&result.stdout)
            .map_err(|error| CliErrorKind::serialize(format!("capture kubernetes: {error}")))?;
        let pods = value["items"]
            .as_array()
            .map(|items| {
                items
                    .par_iter()
                    .map(|item| KubernetesPodSnapshot {
                        namespace: item["metadata"]["namespace"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string(),
                        name: item["metadata"]["name"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string(),
                        phase: item["status"]["phase"].as_str().map(str::to_string),
                        ready: item["status"]["containerStatuses"].as_array().is_some_and(
                            |statuses| {
                                !statuses.is_empty()
                                    && statuses
                                        .iter()
                                        .all(|status| status["ready"].as_bool().unwrap_or(false))
                            },
                        ),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(StateCaptureSnapshot::Kubernetes(
            KubernetesCaptureSnapshot { pods },
        ))
    }

    fn capture_universal_snapshot(&self) -> Result<StateCaptureSnapshot, CliError> {
        let network = self
            .docker_network()
            .ok()
            .map_or_else(|| "harness-default".to_string(), str::to_string);
        let filter = format!("network={network}");
        let containers = self
            .services
            .docker()?
            .list_formatted(&["--filter", &filter], "{{json .}}")?;
        let container_rows = containers
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
            .collect();
        let (dataplanes, dataplanes_error) = match self.query_dataplanes("default") {
            Ok(dataplanes) => (dataplanes, None),
            Err(error) => {
                warn!(%error, "CP API dataplanes query failed");
                (
                    UniversalDataplaneCollection::default(),
                    Some(error.to_string()),
                )
            }
        };
        Ok(StateCaptureSnapshot::Universal(UniversalCaptureSnapshot {
            containers: container_rows,
            dataplanes,
            dataplanes_error,
        }))
    }
}
