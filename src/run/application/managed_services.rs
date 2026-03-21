use crate::errors::CliError;
use crate::run::services::ServiceStatusRecord;

use super::RunApplication;
use super::dependencies::RunDependencies;

impl RunApplication {
    /// List all managed service containers without requiring a tracked run.
    ///
    /// # Errors
    /// Returns `CliError` when docker is unavailable or listing fails.
    pub fn list_managed_service_containers() -> Result<Vec<ServiceStatusRecord>, CliError> {
        let dependencies = RunDependencies::production();
        let docker = dependencies.docker_required()?;
        let result = docker.list_formatted(
            &["--filter", "label=io.harness.service=true"],
            "{{.Names}}\t{{.Status}}",
        )?;
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

    /// Remove a managed service container by name without requiring a tracked run.
    ///
    /// # Errors
    /// Returns `CliError` when docker is unavailable or the removal fails.
    pub fn remove_managed_service_container(name: &str) -> Result<(), CliError> {
        let dependencies = RunDependencies::production();
        let docker = dependencies.docker_required()?;
        docker.remove(name)?;
        Ok(())
    }
}
