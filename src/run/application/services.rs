use crate::errors::CliError;
use crate::infra::exec::{CommandResult, HttpMethod};
use crate::run::services::service_lifecycle;
use crate::run::services::{ServiceStatusRecord, StartServiceRequest};
use crate::run::state_capture::UniversalDataplaneCollection;

use super::RunApplication;

impl RunApplication {
    #[must_use]
    pub fn service_container_filter(&self) -> String {
        service_lifecycle::run_service_filter(&self.layout().run_id)
    }

    /// List service containers scoped to the current run.
    ///
    /// # Errors
    /// Returns `CliError` on docker invocation failures.
    pub fn list_service_containers(&self) -> Result<Vec<ServiceStatusRecord>, CliError> {
        service_lifecycle::read_service_container_rows(
            self.services.docker()?,
            &self.service_container_filter(),
        )
    }

    /// Query the control plane for dataplanes in the target mesh.
    ///
    /// # Errors
    /// Returns `CliError` when the control-plane request fails.
    pub(crate) fn query_dataplanes(
        &self,
        mesh: &str,
    ) -> Result<UniversalDataplaneCollection, CliError> {
        let path = format!("/meshes/{mesh}/dataplanes");
        self.call_control_plane_json(&path, HttpMethod::Get, None)
            .map(UniversalDataplaneCollection::from_api_value)
    }

    /// Start a tracked universal service container and attach a Kuma dataplane.
    ///
    /// # Errors
    /// Returns `CliError` when the tracked run is missing universal access details
    /// or when container setup fails.
    pub fn start_service(&self, request: &StartServiceRequest<'_>) -> Result<(), CliError> {
        let docker = self.services.docker()?;
        let access = self.control_plane_access()?;
        let network = self.docker_network()?;
        let service_image = self.service_image(request.image)?;
        let xds = self.xds_access()?;
        service_lifecycle::start_tracked_service_container(
            docker,
            &self.layout().run_id,
            &access,
            xds,
            network,
            service_image.as_ref(),
            request,
        )
    }

    /// Read or stream logs for a tracked cluster container.
    ///
    /// Returns `None` when logs are streamed directly to the terminal.
    ///
    /// # Errors
    /// Returns `CliError` on docker invocation failures.
    pub fn service_logs(
        &self,
        name: &str,
        tail: u32,
        follow: bool,
    ) -> Result<Option<CommandResult>, CliError> {
        let container = self.resolve_container_name(name);
        service_lifecycle::read_service_logs(
            self.services.docker()?,
            container.as_ref(),
            tail,
            follow,
        )
    }
}
