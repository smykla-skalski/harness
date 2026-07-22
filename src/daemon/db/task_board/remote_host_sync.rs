use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use crate::daemon::db::{CliError, db_error};
use crate::errors::CliErrorKind;
use crate::task_board::{
    TaskBoardExecutionHostConfig, TaskBoardLocalExecutionHostConfig, TaskBoardOrchestratorSettings,
    validate_execution_host_configs, validate_local_execution_host_config,
};

use super::super::remote_assignment_cleanup::active_remote_assignments_in_tx;

pub(in crate::daemon::db::task_board) async fn sync_remote_hosts_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    settings: &TaskBoardOrchestratorSettings,
    configuration_revision: i64,
) -> Result<(), CliError> {
    validate_execution_host_configs(&settings.execution_hosts)?;
    validate_local_execution_host_config(&settings.local_execution_host)?;
    for host in &settings.execution_hosts {
        upsert_configured_host(transaction, host, configuration_revision).await?;
    }
    disable_removed_remote_hosts(transaction, configuration_revision).await?;
    sync_local_executor_host(
        transaction,
        &settings.local_execution_host,
        configuration_revision,
    )
    .await
}

async fn sync_local_executor_host(
    transaction: &mut Transaction<'_, Sqlite>,
    host: &TaskBoardLocalExecutionHostConfig,
    revision: i64,
) -> Result<(), CliError> {
    refuse_active_local_executor_replacement(transaction, &host.host_id).await?;
    query(
        "UPDATE task_board_execution_hosts SET
           enabled = 0,
           observed_host_instance_id = NULL,
           observed_protocol_version = NULL,
           observed_capabilities_json = NULL,
           observed_repositories_json = NULL,
           observed_runtimes_json = NULL,
           observed_capacity = NULL,
           observed_active_assignments = NULL,
           observed_state = NULL,
           observed_heartbeat_at = NULL,
           observed_received_at = NULL,
           advertisement_sha256 = NULL,
           updated_at = ?2
         WHERE host_role = 'executor_self' AND (?1 = '' OR host_id != ?1)",
    )
    .bind(&host.host_id)
    .bind(crate::daemon::db::utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("disable replaced local executor: {error}")))?;
    if host.host_id.is_empty() {
        return Ok(());
    }
    let now = crate::daemon::db::utc_now();
    let changed = query(
        "INSERT INTO task_board_execution_hosts (
           host_id, host_role, configured_endpoint, configured_leaf_sha256,
           configured_credential_reference, configuration_revision, enabled,
           created_at, updated_at
         ) VALUES (?1, 'executor_self', NULL, NULL, NULL, ?2, ?3, ?4, ?4)
         ON CONFLICT(host_id) DO UPDATE SET
           configuration_revision = excluded.configuration_revision,
           enabled = excluded.enabled,
           updated_at = excluded.updated_at
         WHERE task_board_execution_hosts.host_role = 'executor_self'",
    )
    .bind(&host.host_id)
    .bind(revision)
    .bind(host.enabled)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("sync local executor identity: {error}")))?
    .rows_affected();
    if changed == 1 {
        if !host.enabled {
            clear_host_observation(transaction, &host.host_id, "executor_self").await?;
        }
        Ok(())
    } else {
        Err(db_error(format!(
            "local executor '{}' conflicts with a controller remote host",
            host.host_id
        )))
    }
}

async fn disable_removed_remote_hosts(
    transaction: &mut Transaction<'_, Sqlite>,
    current_revision: i64,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_execution_hosts SET
           enabled = 0,
           observed_host_instance_id = NULL,
           observed_protocol_version = NULL,
           observed_capabilities_json = NULL,
           observed_repositories_json = NULL,
           observed_runtimes_json = NULL,
           observed_capacity = NULL,
           observed_active_assignments = NULL,
           observed_state = NULL,
           observed_heartbeat_at = NULL,
           observed_received_at = NULL,
           advertisement_sha256 = NULL,
           updated_at = ?2
         WHERE host_role = 'controller_remote' AND configuration_revision != ?1",
    )
    .bind(current_revision)
    .bind(crate::daemon::db::utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("disable removed remote hosts: {error}")))?;
    Ok(())
}

async fn clear_host_observation(
    transaction: &mut Transaction<'_, Sqlite>,
    host_id: &str,
    host_role: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_execution_hosts SET
           observed_host_instance_id = NULL,
           observed_protocol_version = NULL,
           observed_capabilities_json = NULL,
           observed_repositories_json = NULL,
           observed_runtimes_json = NULL,
           observed_capacity = NULL,
           observed_active_assignments = NULL,
           observed_state = NULL,
           observed_heartbeat_at = NULL,
           observed_received_at = NULL,
           advertisement_sha256 = NULL
         WHERE host_id = ?1 AND host_role = ?2",
    )
    .bind(host_id)
    .bind(host_role)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "clear disabled execution host observation: {error}"
        ))
    })?;
    Ok(())
}

async fn refuse_active_local_executor_replacement(
    transaction: &mut Transaction<'_, Sqlite>,
    requested_host_id: &str,
) -> Result<(), CliError> {
    let candidate_hosts = query_scalar::<_, String>(
        "SELECT hosts.host_id
         FROM task_board_execution_hosts AS hosts
         WHERE hosts.host_role = 'executor_self'
           AND (?1 = '' OR hosts.host_id != ?1)
         ORDER BY hosts.host_id",
    )
    .bind(requested_host_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "fence local executor identity replacement: {error}"
        ))
    })?;
    for active_host in candidate_hosts {
        if active_remote_assignments_in_tx(transaction, &active_host).await? > 0 {
            return Err(CliErrorKind::concurrent_modification(format!(
                "local executor '{active_host}' has active remote assignments; identity replacement is fenced"
            ))
            .into());
        }
    }
    Ok(())
}

async fn upsert_configured_host(
    transaction: &mut Transaction<'_, Sqlite>,
    host: &TaskBoardExecutionHostConfig,
    revision: i64,
) -> Result<(), CliError> {
    let existing = query_as::<_, (String, Option<String>, Option<String>, Option<String>, bool)>(
        "SELECT host_role, configured_endpoint, configured_leaf_sha256,
                configured_credential_reference, enabled
         FROM task_board_execution_hosts WHERE host_id = ?1",
    )
    .bind(&host.host_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load configured remote host: {error}")))?;
    let preserve_observation =
        existing
            .as_ref()
            .is_some_and(|(role, endpoint, leaf, credential, enabled)| {
                role == "controller_remote"
                    && *enabled
                    && host.enabled
                    && endpoint.as_deref() == Some(host.endpoint.as_str())
                    && leaf.as_deref() == Some(host.certificate_fingerprint.as_str())
                    && credential.as_deref() == Some(host.credential_reference.as_str())
            });
    let now = crate::daemon::db::utc_now();
    let changed = query(
        "INSERT INTO task_board_execution_hosts (
           host_id, host_role, configured_endpoint, configured_leaf_sha256,
           configured_credential_reference, configuration_revision, enabled,
           created_at, updated_at
         ) VALUES (?1, 'controller_remote', ?2, ?3, ?4, ?5, ?6, ?7, ?7)
         ON CONFLICT(host_id) DO UPDATE SET
           host_role = 'controller_remote',
           configured_endpoint = excluded.configured_endpoint,
           configured_leaf_sha256 = excluded.configured_leaf_sha256,
           configured_credential_reference = excluded.configured_credential_reference,
           configuration_revision = excluded.configuration_revision,
           enabled = excluded.enabled,
           updated_at = excluded.updated_at
         WHERE task_board_execution_hosts.host_role
             IN ('controller_remote', 'legacy_tombstone')",
    )
    .bind(&host.host_id)
    .bind(&host.endpoint)
    .bind(&host.certificate_fingerprint)
    .bind(&host.credential_reference)
    .bind(revision)
    .bind(host.enabled)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("sync configured remote host: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(db_error(format!(
            "remote host '{}' conflicts with a local executor identity",
            host.host_id
        )));
    }
    if !preserve_observation {
        clear_host_observation(transaction, &host.host_id, "controller_remote").await?;
    }
    Ok(())
}
