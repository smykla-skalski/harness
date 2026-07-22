use chrono::{DateTime, SecondsFormat, Utc};
use sha2::{Digest, Sha256};
use sqlx::{query, query_as};

use super::items::bump_change_in_tx;
use super::mapper::{parse_json, to_json};
use super::remote_assignment_cleanup::active_remote_assignments_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::errors::CliErrorKind;
use crate::task_board::{
    TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS, TaskBoardExecutionHostAdvertisement,
    TaskBoardExecutionHostConfig, TaskBoardExecutionPhase, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorWorkflow, TaskBoardPhaseCapabilityProfile, TaskBoardRemoteHostState,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, normalize_repository_slug,
    remote_capability_for_phase, validate_execution_host_advertisement,
    validate_execution_host_observation,
};

#[path = "remote_host_sync.rs"]
mod sync;
pub(super) use sync::sync_remote_hosts_in_tx;

pub(crate) const REMOTE_HOST_CHANGE_SCOPE: &str = "task_board:remote_hosts";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteHostSelection {
    pub(crate) config: TaskBoardExecutionHostConfig,
    pub(crate) advertisement: TaskBoardExecutionHostAdvertisement,
    pub(crate) configuration_revision: u64,
    pub(crate) received_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteHostTrustFence {
    pub(crate) config: TaskBoardExecutionHostConfig,
    pub(crate) configuration_revision: u64,
}

impl AsyncDaemonDb {
    #[cfg(test)]
    pub(crate) async fn task_board_remote_host_active_assignment_count_for_test(
        &self,
        host_id: &str,
    ) -> Result<u32, CliError> {
        active_assignment_count(self, host_id).await
    }

    pub(crate) async fn task_board_remote_host_trust_fence(
        &self,
        host_id: &str,
    ) -> Result<TaskBoardRemoteHostTrustFence, CliError> {
        let row = query_as::<_, HostRow>(HostRow::SELECT_BY_ID)
            .bind(host_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load configured remote host: {error}")))?
            .ok_or_else(|| permission_denied(host_id))?;
        row.trust_fence()
    }

    pub(crate) async fn record_task_board_execution_host_observation_fenced(
        &self,
        advertisement: &TaskBoardExecutionHostAdvertisement,
        received_at: &str,
        expected: &TaskBoardRemoteHostTrustFence,
    ) -> Result<TaskBoardRemoteHostSelection, CliError> {
        self.record_task_board_execution_host_observation_state_fenced(
            advertisement,
            received_at,
            expected,
            TaskBoardRemoteHostState::Healthy,
        )
        .await
    }

    #[cfg(test)]
    pub(crate) async fn record_task_board_execution_host_observation_state_for_test(
        &self,
        advertisement: &TaskBoardExecutionHostAdvertisement,
        received_at: &str,
        expected: &TaskBoardRemoteHostTrustFence,
        state: TaskBoardRemoteHostState,
    ) -> Result<TaskBoardRemoteHostSelection, CliError> {
        self.record_task_board_execution_host_observation_state_fenced(
            advertisement,
            received_at,
            expected,
            state,
        )
        .await
    }

    async fn record_task_board_execution_host_observation_state_fenced(
        &self,
        advertisement: &TaskBoardExecutionHostAdvertisement,
        received_at: &str,
        expected: &TaskBoardRemoteHostTrustFence,
        state: TaskBoardRemoteHostState,
    ) -> Result<TaskBoardRemoteHostSelection, CliError> {
        validate_execution_host_advertisement(advertisement)?;
        if advertisement.host_id != expected.config.host_id || !expected.config.enabled {
            return Err(permission_denied(&advertisement.host_id));
        }
        let state = observed_state_label(state)?;
        let received_at = canonical_time(received_at, "host observation receipt")?;
        if !advertisement.heartbeat_is_fresh_at(received_at) {
            return Err(parse_error(
                "remote host heartbeat is expired or later than its receipt time",
            ));
        }
        let mut transaction = self
            .begin_immediate_transaction("task board remote host observation")
            .await?;
        let received_at = received_at.to_rfc3339_opts(SecondsFormat::AutoSi, true);
        validate_execution_host_observation(&expected.config, advertisement)?;
        let selection = TaskBoardRemoteHostSelection {
            config: expected.config.clone(),
            advertisement: advertisement.clone(),
            configuration_revision: expected.configuration_revision,
            received_at: received_at.clone(),
        };
        let changed = query(
            "UPDATE task_board_execution_hosts SET
             observed_host_instance_id = ?2, observed_protocol_version = ?3,
             observed_capabilities_json = ?4, observed_repositories_json = ?5,
             observed_runtimes_json = ?6, observed_capacity = ?7,
             observed_active_assignments = ?8, observed_state = ?9,
             observed_received_at = ?10, observed_heartbeat_at = ?11,
             advertisement_sha256 = ?12, updated_at = ?10
             WHERE host_id = ?1 AND host_role = 'controller_remote'
               AND configuration_revision = ?13 AND enabled = ?14
               AND configured_endpoint = ?15 AND configured_leaf_sha256 = ?16
               AND configured_credential_reference = ?17",
        )
        .bind(&advertisement.host_id)
        .bind(&advertisement.host_instance_id)
        .bind(i64::from(advertisement.protocol_version))
        .bind(to_json(
            &advertisement.capabilities,
            "remote host capabilities",
        )?)
        .bind(to_json(
            &advertisement.repositories,
            "remote host repositories",
        )?)
        .bind(to_json(&advertisement.runtimes, "remote host runtimes")?)
        .bind(i64::from(advertisement.capacity))
        .bind(i64::from(advertisement.active_assignments))
        .bind(state)
        .bind(&received_at)
        .bind(&advertisement.heartbeat_at)
        .bind(advertisement_digest(advertisement)?)
        .bind(
            i64::try_from(expected.configuration_revision)
                .map_err(|_| db_error("remote host configuration revision is out of range"))?,
        )
        .bind(expected.config.enabled)
        .bind(&expected.config.endpoint)
        .bind(&expected.config.certificate_fingerprint)
        .bind(&expected.config.credential_reference)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("record remote host observation: {error}")))?
        .rows_affected();
        if changed != 1 {
            return Err(CliErrorKind::concurrent_modification(
                "remote host trust configuration changed before observation storage",
            )
            .into());
        }
        bump_change_in_tx(&mut transaction, REMOTE_HOST_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote host observation: {error}")))?;
        Ok(selection)
    }

    #[cfg(test)]
    pub(crate) async fn record_task_board_execution_host_observation(
        &self,
        advertisement: &TaskBoardExecutionHostAdvertisement,
        received_at: &str,
    ) -> Result<TaskBoardRemoteHostSelection, CliError> {
        let expected = self
            .task_board_remote_host_trust_fence(&advertisement.host_id)
            .await?;
        self.record_task_board_execution_host_observation_fenced(
            advertisement,
            received_at,
            &expected,
        )
        .await
    }

    pub(crate) async fn resolve_task_board_remote_host(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        source_repository: &str,
        phase: TaskBoardExecutionPhase,
        runtime: &str,
        now: &str,
    ) -> Result<Option<TaskBoardRemoteHostSelection>, CliError> {
        let Some(policy_repository) = execution.snapshot.execution_repository.as_deref() else {
            return Ok(None);
        };
        let Some(policy_repository) = normalize_repository_slug(Some(policy_repository)) else {
            return Err(parse_error(
                "workflow execution repository is not canonical",
            ));
        };
        let Some(source_repository) = normalize_repository_slug(Some(source_repository)) else {
            return Err(parse_error("remote source repository is not canonical"));
        };
        let required_capability = remote_capability_for_phase(phase)?;
        let now = canonical_time(now, "remote host resolution time")?;
        let settings = self.task_board_orchestrator_settings_snapshot().await?;
        let settings_revision = u64::try_from(settings.row_revision)
            .map_err(|_| db_error("settings revision is out of range"))?;
        if settings_revision != execution.snapshot.configuration_revision {
            return Ok(None);
        }
        let Some(repository_config) = configured_repository(
            &settings.settings,
            &policy_repository,
            execution.snapshot.workflow_kind,
        ) else {
            return Ok(None);
        };
        if settings.settings.execution_hosts.is_empty() {
            return Ok(None);
        }
        let rows = query_as::<_, HostRow>(HostRow::SELECT_ALL)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("list remote execution hosts: {error}")))?;
        let runtime = runtime.trim().to_ascii_lowercase();
        if runtime.is_empty() {
            return Err(parse_error("remote attempt runtime is missing"));
        }
        let mut eligible = Vec::new();
        for row in rows {
            let Some(selection) = row.observed_selection()? else {
                continue;
            };
            if selection.configuration_revision != settings_revision
                || !host_is_eligible(
                    &selection,
                    &source_repository,
                    required_capability,
                    &runtime,
                    now,
                )?
            {
                continue;
            }
            let active = active_assignment_count(self, &selection.config.host_id)
                .await?
                .max(selection.advertisement.active_assignments);
            if active < selection.advertisement.capacity {
                eligible.push((selection, active));
            }
        }
        if let Some(preferred) = repository_config.preferred_host_id.as_deref()
            && let Some(index) = eligible
                .iter()
                .position(|(host, _)| host.config.host_id == preferred)
        {
            return Ok(Some(eligible.swap_remove(index).0));
        }
        eligible.sort_by(|(left, left_active), (right, right_active)| {
            available_capacity(right, *right_active)
                .cmp(&available_capacity(left, *left_active))
                .then_with(|| left.config.host_id.cmp(&right.config.host_id))
        });
        Ok(eligible.into_iter().next().map(|(host, _)| host))
    }
}

fn observed_state_label(state: TaskBoardRemoteHostState) -> Result<&'static str, CliError> {
    match state {
        TaskBoardRemoteHostState::Healthy
        | TaskBoardRemoteHostState::Degraded
        | TaskBoardRemoteHostState::Unavailable => Ok(state.as_str()),
        TaskBoardRemoteHostState::Disabled => Err(parse_error(
            "disabled remote host state is operator-owned and cannot be observed",
        )),
    }
}

fn configured_repository<'a>(
    settings: &'a TaskBoardOrchestratorSettings,
    repository: &str,
    kind: TaskBoardWorkflowKind,
) -> Option<&'a crate::task_board::TaskBoardRepositoryAutomationConfig> {
    let workflow = workflow_setting(kind)?;
    settings.repositories.iter().find(|candidate| {
        candidate.enabled
            && normalize_repository_slug(Some(&candidate.repository)).as_deref() == Some(repository)
            && (candidate.workflows.is_empty() || candidate.workflows.contains(&workflow))
    })
}

const fn workflow_setting(kind: TaskBoardWorkflowKind) -> Option<TaskBoardOrchestratorWorkflow> {
    match kind {
        TaskBoardWorkflowKind::DefaultTask => Some(TaskBoardOrchestratorWorkflow::DefaultTask),
        TaskBoardWorkflowKind::PrFix => Some(TaskBoardOrchestratorWorkflow::PrFix),
        TaskBoardWorkflowKind::PrReview => Some(TaskBoardOrchestratorWorkflow::PrReview),
        TaskBoardWorkflowKind::Review => Some(TaskBoardOrchestratorWorkflow::Review),
        TaskBoardWorkflowKind::Unknown => None,
    }
}

fn host_is_eligible(
    selection: &TaskBoardRemoteHostSelection,
    repository: &str,
    capability: TaskBoardPhaseCapabilityProfile,
    runtime: &str,
    now: DateTime<Utc>,
) -> Result<bool, CliError> {
    let host = &selection.advertisement;
    if !selection.config.enabled
        || !receipt_is_fresh(&selection.received_at, now)?
        || !host.heartbeat_is_fresh_at(now)
        || !host.repositories.iter().any(|value| value == repository)
        || !host.capabilities.contains(&capability)
        || !host.runtimes.iter().any(|available| available == runtime)
    {
        return Ok(false);
    }
    Ok(true)
}

async fn active_assignment_count(db: &AsyncDaemonDb, host_id: &str) -> Result<u32, CliError> {
    let mut transaction = db
        .pool()
        .begin()
        .await
        .map_err(|error| db_error(format!("begin active remote assignment count: {error}")))?;
    let count = active_remote_assignments_in_tx(&mut transaction, host_id).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit active remote assignment count: {error}")))?;
    Ok(count)
}

fn available_capacity(selection: &TaskBoardRemoteHostSelection, active: u32) -> u32 {
    selection.advertisement.capacity.saturating_sub(active)
}

fn canonical_time(value: &str, context: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| parse_error(format!("{context}: {error}")))
}

fn receipt_is_fresh(value: &str, now: DateTime<Utc>) -> Result<bool, CliError> {
    let received = canonical_time(value, "remote host receipt time")?;
    Ok(received <= now
        && received >= now - chrono::Duration::seconds(TASK_BOARD_REMOTE_HEARTBEAT_TTL_SECONDS))
}

fn advertisement_digest(
    advertisement: &TaskBoardExecutionHostAdvertisement,
) -> Result<String, CliError> {
    let encoded = serde_json::to_vec(advertisement)
        .map_err(|error| db_error(format!("serialize host advertisement: {error}")))?;
    Ok(hex::encode(Sha256::digest(encoded)))
}

fn permission_denied(host_id: &str) -> CliError {
    CliErrorKind::session_permission_denied(format!(
        "remote execution host '{host_id}' is not operator-configured"
    ))
    .into()
}

fn parse_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(message.into()).into()
}

#[derive(sqlx::FromRow)]
struct HostRow {
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
    const SELECT_ALL: &'static str = "SELECT host_id, configured_endpoint,
        configured_leaf_sha256, configured_credential_reference, configuration_revision,
        enabled, observed_host_instance_id, observed_protocol_version,
        observed_capabilities_json, observed_repositories_json, observed_runtimes_json,
        observed_capacity, observed_active_assignments, observed_state, observed_received_at,
        observed_heartbeat_at
        FROM task_board_execution_hosts
        WHERE host_role = 'controller_remote' ORDER BY host_id";
    const SELECT_BY_ID: &'static str = "SELECT host_id, configured_endpoint,
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

    fn trust_fence(&self) -> Result<TaskBoardRemoteHostTrustFence, CliError> {
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

    fn observed_selection(self) -> Result<Option<TaskBoardRemoteHostSelection>, CliError> {
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
