use super::{TaskBoardRemoteHostSelection, TaskBoardRemoteHostTrustFence};
use crate::daemon::db::task_board::mapper::parse_json;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardExecutionHostAdvertisement, TaskBoardExecutionHostConfig, TaskBoardRemoteHostState,
    validate_execution_host_advertisement,
};

#[derive(sqlx::FromRow)]
pub(super) struct HostRow {
    host_id: String,
    configured_endpoint: String,
    configured_leaf_sha256: String,
    configured_credential_reference: String,
    configuration_revision: i64,
    enabled: bool,
    observed_host_instance_id: Option<String>,
    observed_protocol_version: Option<i64>,
    observed_capabilities_json: Option<String>,
    observed_repositories_json: Option<String>,
    observed_runtimes_json: Option<String>,
    observed_capacity: Option<i64>,
    observed_active_assignments: Option<i64>,
    observed_state: Option<String>,
    observed_received_at: Option<String>,
    observed_heartbeat_at: Option<String>,
}

impl HostRow {
    pub(super) const SELECT_ALL: &'static str = "SELECT host_id, configured_endpoint,
        configured_leaf_sha256, configured_credential_reference, configuration_revision,
        enabled, observed_host_instance_id, observed_protocol_version,
        observed_capabilities_json, observed_repositories_json, observed_runtimes_json,
        observed_capacity, observed_active_assignments, observed_state, observed_received_at,
        observed_heartbeat_at
        FROM task_board_execution_hosts
        WHERE host_role = 'controller_remote' ORDER BY host_id";
    pub(super) const SELECT_BY_ID: &'static str = "SELECT host_id, configured_endpoint,
        configured_leaf_sha256, configured_credential_reference, configuration_revision,
        enabled, observed_host_instance_id, observed_protocol_version,
        observed_capabilities_json, observed_repositories_json, observed_runtimes_json,
        observed_capacity, observed_active_assignments, observed_state, observed_received_at,
        observed_heartbeat_at
        FROM task_board_execution_hosts
        WHERE host_id = ?1 AND host_role = 'controller_remote'";

    fn config(&self) -> TaskBoardExecutionHostConfig {
        TaskBoardExecutionHostConfig {
            host_id: self.host_id.clone(),
            endpoint: self.configured_endpoint.clone(),
            certificate_fingerprint: self.configured_leaf_sha256.clone(),
            credential_reference: self.configured_credential_reference.clone(),
            enabled: self.enabled,
        }
    }

    pub(super) fn trust_fence(&self) -> Result<TaskBoardRemoteHostTrustFence, CliError> {
        Ok(TaskBoardRemoteHostTrustFence {
            config: self.config(),
            configuration_revision: u64::try_from(self.configuration_revision)
                .map_err(|_| db_error("remote host configuration revision is out of range"))?,
        })
    }

    fn selection(
        &self,
        advertisement: TaskBoardExecutionHostAdvertisement,
        received_at: &str,
    ) -> Result<TaskBoardRemoteHostSelection, CliError> {
        let trust = self.trust_fence()?;
        Ok(TaskBoardRemoteHostSelection {
            config: self.config(),
            advertisement,
            configuration_revision: trust.configuration_revision,
            received_at: received_at.to_string(),
        })
    }

    pub(super) fn observed_selection(
        self,
    ) -> Result<Option<TaskBoardRemoteHostSelection>, CliError> {
        let Some(host_instance_id) = self.observed_host_instance_id.clone() else {
            return Ok(None);
        };
        if self.observed_state.as_deref() != Some(TaskBoardRemoteHostState::Healthy.as_str()) {
            return Ok(None);
        }
        let advertisement = TaskBoardExecutionHostAdvertisement {
            host_id: self.host_id.clone(),
            host_instance_id,
            protocol_version: u32::try_from(required(self.observed_protocol_version, "protocol")?)
                .map_err(|_| db_error("remote host protocol is out of range"))?,
            repositories: parse_json(
                required(self.observed_repositories_json.as_deref(), "repositories")?,
                "remote host repositories",
            )?,
            runtimes: parse_json(
                required(self.observed_runtimes_json.as_deref(), "runtimes")?,
                "remote host runtimes",
            )?,
            capabilities: parse_json(
                required(self.observed_capabilities_json.as_deref(), "capabilities")?,
                "remote host capabilities",
            )?,
            capacity: u32::try_from(required(self.observed_capacity, "capacity")?)
                .map_err(|_| db_error("remote host capacity is out of range"))?,
            active_assignments: u32::try_from(required(
                self.observed_active_assignments,
                "active assignments",
            )?)
            .map_err(|_| db_error("remote host active assignments are out of range"))?,
            heartbeat_at: required(self.observed_heartbeat_at.clone(), "heartbeat time")?,
        };
        validate_execution_host_advertisement(&advertisement)?;
        let received_at = required(self.observed_received_at.as_deref(), "receipt time")?;
        self.selection(advertisement, received_at).map(Some)
    }
}

fn required<T>(value: Option<T>, field: &str) -> Result<T, CliError> {
    value.ok_or_else(|| db_error(format!("observed remote host {field} is missing")))
}
