use sqlx::{Sqlite, Transaction, query, query_as};

use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, nonblank, to_i64,
};
use super::remote_lifecycle_trust::{
    TaskBoardRemoteLifecycleTrustSnapshot, load_generation_lifecycle_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, TaskBoardRemoteHostTrustFence, db_error};
use crate::task_board::TaskBoardExecutionHostConfig;

#[path = "remote_operation_trust/cleanup.rs"]
mod cleanup;
#[path = "remote_operation_trust/operation.rs"]
mod operation;
pub(super) use cleanup::{
    claim_cleanup_observation_trust_in_tx, consume_cleanup_observation_trust_in_tx,
};
pub(super) use operation::{
    abandon_controller_operation_trust_in_tx, claim_controller_operation_trust_in_tx,
    consume_controller_operation_trust_in_tx, consume_pending_operation_replay_trust_in_tx,
    persist_operation_trust_in_tx, require_generation_replay_trust_in_tx,
    require_pending_operation_replay_trust_in_tx,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteOperationKind {
    UploadSourceBundle,
    Offer,
    Claim,
    Renew,
    Status,
    Cancel,
    Settle,
    FetchArtifact,
    ObserveCleanup,
}

impl TaskBoardRemoteOperationKind {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::UploadSourceBundle => "upload_source_bundle",
            Self::Offer => "offer",
            Self::Claim => "claim",
            Self::Renew => "renew",
            Self::Status => "status",
            Self::Cancel => "cancel",
            Self::Settle => "settle",
            Self::FetchArtifact => "fetch_artifact",
            Self::ObserveCleanup => "observe_cleanup",
        }
    }

    pub(crate) const fn requires_enabled_host(self) -> bool {
        matches!(
            self,
            Self::UploadSourceBundle | Self::Offer | Self::Claim | Self::Renew
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteOperationTrustFence {
    pub(crate) host: TaskBoardRemoteHostTrustFence,
    pub(crate) observed_host_instance_id: String,
    pub(crate) advertisement_sha256: String,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_remote_operation_trust_fence(
        &self,
        host_id: &str,
    ) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
        nonblank(host_id, "remote operation trust host")?;
        query_as::<_, OperationHostRow>(OperationHostRow::SELECT)
            .bind(host_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load remote operation trust: {error}")))?
            .ok_or_else(|| concurrent("remote operation host is not configured"))?
            .into_fence()
    }

    pub(crate) async fn complete_task_board_remote_operation_trust(
        &self,
        assignment_id: &str,
        kind: TaskBoardRemoteOperationKind,
        request_sha256: &str,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board remote operation trust completion")
            .await?;
        let assignment = super::remote_assignment_lease::require_assignment(
            &mut transaction,
            assignment_id,
        )
        .await?;
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            kind,
            request_sha256,
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote operation trust: {error}")))
    }

    pub(crate) async fn task_board_remote_lifecycle_operation_trust_fence(
        &self,
        assignment_id: &str,
        kind: TaskBoardRemoteOperationKind,
    ) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
        if kind.requires_enabled_host() {
            return Err(db_error(
                "remote lifecycle trust fence requested for a fresh operation kind",
            ));
        }
        let mut transaction = self
            .begin_immediate_transaction("task board lifecycle operation trust")
            .await?;
        let assignment = super::remote_assignment_lease::require_assignment(
            &mut transaction,
            assignment_id,
        )
        .await?;
        let generation = load_generation_lifecycle_trust_in_tx(
            &mut transaction,
            assignment_id,
            assignment.fencing_epoch,
        )
        .await?;
        let fence = load_operation_fence_for_kind_in_tx(
            &mut transaction,
            &assignment,
            kind,
            &generation,
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit lifecycle operation trust: {error}")))?;
        Ok(fence)
    }
}

pub(super) fn has_controller_operation_trust(
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> bool {
    assignment.controller_operation.is_some()
}

pub(super) async fn load_operation_fence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    host_id: &str,
) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
    query_as::<_, OperationHostRow>(OperationHostRow::SELECT)
        .bind(host_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load fenced remote operation host: {error}")))?
        .ok_or_else(|| concurrent("remote operation host disappeared"))?
        .into_fence()
}

pub(super) async fn load_operation_fence_for_kind_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    generation: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
    let row = query_as::<_, OperationHostRow>(OperationHostRow::SELECT)
        .bind(&assignment.host_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load kind-aware remote operation host: {error}")))?
        .ok_or_else(|| concurrent("remote operation host disappeared"))?;
    if kind.requires_enabled_host() {
        row.into_fence()
    } else {
        row.into_lifecycle_fence(generation)
    }
}

pub(super) async fn require_current_operation_fence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    require_operation_fence_in_tx(transaction, expected, true).await
}

pub(super) async fn require_current_operation_fence_for_kind_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardRemoteOperationTrustFence,
    kind: TaskBoardRemoteOperationKind,
) -> Result<(), CliError> {
    require_operation_fence_in_tx(transaction, expected, kind.requires_enabled_host()).await
}

pub(super) async fn require_source_recovery_operation_fence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    require_operation_fence_in_tx(transaction, expected, false).await
}

async fn require_operation_fence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardRemoteOperationTrustFence,
    require_enabled: bool,
) -> Result<(), CliError> {
    let current = load_operation_fence_in_tx(transaction, &expected.host.config.host_id).await?;
    if current == *expected && (!require_enabled || current.host.config.enabled) {
        Ok(())
    } else {
        Err(concurrent(
            "remote host trust changed during source recovery I/O",
        ))
    }
}

pub(super) async fn consume_successor_recovery_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    current: &TaskBoardRemoteOperationTrustFence,
) -> Result<(), CliError> {
    require_operation_fence_in_tx(transaction, current, false).await?;
    require_sha256(request_sha256, "successor recovery request digest")?;
    let operation = assignment.controller_operation.as_ref().ok_or_else(|| {
        concurrent("successor recovery lost its predecessor operation token")
    })?;
    let operation_fence = operation.fence.as_ref().ok_or_else(|| {
        concurrent("successor recovery operation has no immutable lifecycle fence")
    })?;
    let predecessor = assignment.target_host_instance_id.as_deref().ok_or_else(|| {
        concurrent("successor recovery predecessor instance is missing")
    })?;
    operation_fence.require_generation_binding(
        &assignment.host_id,
        assignment.configuration_revision,
        Some(predecessor),
    )?;
    operation_fence.require_stable_transport(&current.host)?;
    let operation_fence_json = operation_fence.encoded()?;
    let exact = current.host.config.host_id == assignment.host_id
        && assignment.configuration_revision == Some(current.host.configuration_revision)
        && predecessor != current.observed_host_instance_id
        && operation.kind == kind.as_str()
        && operation.request_sha256 == request_sha256;
    if !exact {
        return Err(concurrent(
            "successor recovery does not match the immutable predecessor operation",
        ));
    }
    let rows = query(
        "UPDATE task_board_remote_assignments SET
         controller_operation_kind = NULL,
         controller_operation_request_sha256 = NULL,
         controller_operation_trust_sha256 = NULL,
         controller_operation_fence_json = NULL,
         controller_operation_fence_sha256 = NULL
         WHERE assignment_id = ?1 AND fencing_epoch = ?2
           AND host_id = ?3 AND target_host_instance_id = ?4
           AND configuration_revision = ?5
           AND controller_operation_kind = ?6
           AND controller_operation_request_sha256 = ?7
           AND controller_operation_trust_sha256 = ?8
           AND controller_operation_fence_json = ?9
           AND controller_operation_fence_sha256 = ?10",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "successor recovery fencing epoch",
    )?)
    .bind(&assignment.host_id)
    .bind(predecessor)
    .bind(to_i64(
        current.host.configuration_revision,
        "successor recovery configuration revision",
    )?)
    .bind(kind.as_str())
    .bind(request_sha256)
    .bind(&operation.trust_sha256)
    .bind(operation_fence_json)
    .bind(&operation_fence.snapshot_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("clear successor recovery operation: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(
            "successor recovery operation clear lost its exact predecessor fence",
        ))
    }
}

fn require_sha256(value: &str, context: &str) -> Result<(), CliError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(db_error(format!("{context} is not canonical lowercase SHA-256")))
    }
}

#[derive(sqlx::FromRow)]
struct OperationHostRow {
    host_id: String,
    configured_endpoint: String,
    configured_leaf_sha256: String,
    configured_credential_reference: String,
    configuration_revision: i64,
    enabled: bool,
    observed_host_instance_id: Option<String>,
    advertisement_sha256: Option<String>,
}

impl OperationHostRow {
    const SELECT: &'static str = "SELECT host_id, configured_endpoint,
        configured_leaf_sha256, configured_credential_reference, configuration_revision,
        enabled, observed_host_instance_id, advertisement_sha256
        FROM task_board_execution_hosts
        WHERE host_id = ?1 AND host_role = 'controller_remote'";

    fn into_fence(self) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
        let revision = u64::try_from(self.configuration_revision)
            .ok()
            .filter(|revision| *revision > 0)
            .ok_or_else(|| db_error("remote operation host revision is invalid"))?;
        let observed_host_instance_id = self
            .observed_host_instance_id
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| concurrent("remote operation host has no observed instance"))?;
        let advertisement_sha256 = self
            .advertisement_sha256
            .ok_or_else(|| concurrent("remote operation host has no advertisement digest"))?;
        require_sha256(
            &advertisement_sha256,
            "remote operation advertisement digest",
        )?;
        Ok(TaskBoardRemoteOperationTrustFence {
            host: TaskBoardRemoteHostTrustFence {
                config: TaskBoardExecutionHostConfig {
                    host_id: self.host_id,
                    endpoint: self.configured_endpoint,
                    certificate_fingerprint: self.configured_leaf_sha256,
                    credential_reference: self.configured_credential_reference,
                    enabled: self.enabled,
                },
                configuration_revision: revision,
            },
            observed_host_instance_id,
            advertisement_sha256,
        })
    }

    fn into_host_fence(self) -> Result<TaskBoardRemoteHostTrustFence, CliError> {
        let revision = u64::try_from(self.configuration_revision)
            .ok()
            .filter(|revision| *revision > 0)
            .ok_or_else(|| db_error("remote cleanup host revision is invalid"))?;
        Ok(TaskBoardRemoteHostTrustFence {
            config: TaskBoardExecutionHostConfig {
                host_id: self.host_id,
                endpoint: self.configured_endpoint,
                certificate_fingerprint: self.configured_leaf_sha256,
                credential_reference: self.configured_credential_reference,
                enabled: self.enabled,
            },
            configuration_revision: revision,
        })
    }

    fn into_lifecycle_fence(
        self,
        generation: &TaskBoardRemoteLifecycleTrustSnapshot,
    ) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
        let observed = match (
            self.observed_host_instance_id.clone(),
            self.advertisement_sha256.clone(),
        ) {
            (Some(instance), Some(advertisement)) => (instance, advertisement),
            (None, None) => (
                generation.observed_host_instance_id.clone(),
                generation.advertisement_sha256.clone(),
            ),
            _ => {
                return Err(db_error(
                    "remote lifecycle host observation evidence is incomplete",
                ));
            }
        };
        let host = self.into_host_fence()?;
        generation.require_stable_transport(&host)?;
        require_sha256(&observed.1, "remote lifecycle advertisement digest")?;
        Ok(TaskBoardRemoteOperationTrustFence {
            host,
            observed_host_instance_id: observed.0,
            advertisement_sha256: observed.1,
        })
    }
}
