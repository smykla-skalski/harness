use chrono::{DateTime, Duration, Utc};
use sqlx::{Sqlite, Transaction, query_as};

use super::super::remote_assignment_cleanup::active_remote_assignments_in_tx;
use super::{canonical_time, remote_capability_for_phase, to_i64};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::task_board::{
    TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS, TaskBoardPhaseCapabilityProfile,
};

pub(super) async fn host_has_capacity(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    now: DateTime<Utc>,
) -> Result<bool, CliError> {
    let Some(host) = query_as::<_, OfferHostRow>(
        "SELECT host_role, configuration_revision, enabled, observed_host_instance_id,
         observed_capabilities_json, observed_repositories_json, observed_runtimes_json,
         observed_capacity, observed_active_assignments, observed_state,
         observed_heartbeat_at, observed_received_at
         FROM task_board_execution_hosts WHERE host_id = ?1",
    )
    .bind(&request.binding.host_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote assignment host: {error}")))?
    else {
        return Ok(false);
    };
    if !host.matches(request, now)? {
        return Ok(false);
    }
    let active = i64::from(
        active_remote_assignments_in_tx(transaction, &request.binding.host_id).await?,
    );
    Ok(active.max(host.observed_active_assignments.unwrap_or(0))
        < host.observed_capacity.unwrap_or(0))
}

#[derive(sqlx::FromRow)]
struct OfferHostRow {
    host_role: String,
    configuration_revision: i64,
    enabled: bool,
    observed_host_instance_id: Option<String>,
    observed_capabilities_json: Option<String>,
    observed_repositories_json: Option<String>,
    observed_runtimes_json: Option<String>,
    observed_capacity: Option<i64>,
    observed_active_assignments: Option<i64>,
    observed_state: Option<String>,
    observed_heartbeat_at: Option<String>,
    observed_received_at: Option<String>,
}

impl OfferHostRow {
    fn matches(&self, request: &RemoteOfferRequest, now: DateTime<Utc>) -> Result<bool, CliError> {
        let binding = &request.binding;
        let heartbeat = optional_time(self.observed_heartbeat_at.as_deref(), "host heartbeat")?;
        let received = optional_time(self.observed_received_at.as_deref(), "host receipt")?;
        let fresh = |time: Option<DateTime<Utc>>| {
            time.is_some_and(|time| {
                time <= now
                    && time >= now - Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS)
            })
        };
        let capabilities: Vec<TaskBoardPhaseCapabilityProfile> =
            optional_json(self.observed_capabilities_json.as_deref())?;
        let repositories: Vec<String> = optional_json(self.observed_repositories_json.as_deref())?;
        let runtimes: Vec<String> = optional_json(self.observed_runtimes_json.as_deref())?;
        Ok(self.host_role == "controller_remote"
            && self.enabled
            && self.configuration_revision
                == to_i64(
                    binding.configuration_revision,
                    "host configuration revision",
                )?
            && self.observed_host_instance_id.as_deref() == Some(binding.host_instance_id.as_str())
            && self.observed_state.as_deref() == Some("healthy")
            && fresh(heartbeat)
            && fresh(received)
            && self.observed_capacity.is_some_and(|capacity| capacity > 0)
            && self
                .observed_active_assignments
                .is_some_and(|active| active >= 0 && active < self.observed_capacity.unwrap_or(0))
            && capabilities.contains(&remote_capability_for_phase(binding.phase)?)
            && repositories
                .iter()
                .any(|repository| repository == request.source.repository())
            && runtimes.contains(&request.launch.runtime))
    }
}

fn optional_time(value: Option<&str>, field: &str) -> Result<Option<DateTime<Utc>>, CliError> {
    value.map(|value| canonical_time(value, field)).transpose()
}

fn optional_json<T>(value: Option<&str>) -> Result<T, CliError>
where
    T: serde::de::DeserializeOwned + Default,
{
    value.map_or_else(
        || Ok(T::default()),
        |value| {
            serde_json::from_str(value)
                .map_err(|error| db_error(format!("decode remote host observation: {error}")))
        },
    )
}
