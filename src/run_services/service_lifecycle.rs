use crate::errors::CliError;
use crate::exec::HttpMethod;
use crate::state_capture::UniversalDataplaneCollection;

use super::RunServices;
use super::status::ServiceStatusRecord;

impl RunServices {
    #[must_use]
    pub fn service_container_filter(&self) -> String {
        format!("label=io.harness.run-id={}", self.layout().run_id)
    }

    /// List service containers scoped to the current run.
    ///
    /// # Errors
    /// Returns `CliError` on docker invocation failures.
    pub fn list_service_containers(&self) -> Result<Vec<ServiceStatusRecord>, CliError> {
        let filter = self.service_container_filter();
        let result = self
            .docker()?
            .list_formatted(&["--filter", &filter], "{{.Names}}\t{{.Status}}")?;
        Ok(result
            .stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let mut parts = line.splitn(2, '\t');
                ServiceStatusRecord {
                    name: parts.next().unwrap_or_default().to_string(),
                    status: parts.next().unwrap_or_default().to_string(),
                }
            })
            .collect())
    }

    /// Query the control plane for dataplanes in the target mesh.
    ///
    /// # Errors
    /// Returns `CliError` when the control-plane request fails.
    pub fn query_dataplanes(&self, mesh: &str) -> Result<UniversalDataplaneCollection, CliError> {
        let path = format!("/meshes/{mesh}/dataplanes");
        self.call_control_plane_json(&path, HttpMethod::Get, None)
            .map(UniversalDataplaneCollection::from_api_value)
    }
}
