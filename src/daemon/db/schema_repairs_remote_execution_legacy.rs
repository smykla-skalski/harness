use std::collections::BTreeMap;

use super::{CliError, Connection, db_error};
use crate::task_board::{
    TASK_BOARD_REMOTE_PROTOCOL_VERSION, TaskBoardExecutionHostConfig, normalize_repository_slug,
    remote_spki_pin, validate_execution_host_config, validate_execution_host_configs,
};

struct LegacyHostEvidence {
    host_id: String,
    endpoint: String,
    certificate_fingerprint: String,
    credential_reference: String,
    protocol_version: i64,
    capabilities: Vec<String>,
    repositories: Vec<String>,
    capacity: i64,
    active_assignments: i64,
    state: String,
}

pub(super) fn validate_legacy_host_evidence(conn: &Connection) -> Result<(), CliError> {
    let settings_json: String = conn
        .query_row(
            "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .map_err(|error| db_error(format!("read remote host settings: {error}")))?;
    let settings: serde_json::Value = serde_json::from_str(&settings_json)
        .map_err(|error| db_error(format!("decode remote host settings: {error}")))?;
    let configured: Vec<TaskBoardExecutionHostConfig> = serde_json::from_value(
        settings
            .get("execution_hosts")
            .cloned()
            .unwrap_or_else(|| serde_json::Value::Array(Vec::new())),
    )
    .map_err(|error| db_error(format!("decode configured remote hosts: {error}")))?;
    validate_migratable_host_configs(&configured)?;
    let configured_by_id: BTreeMap<&str, &TaskBoardExecutionHostConfig> = configured
        .iter()
        .map(|host| (host.host_id.as_str(), host))
        .collect();

    let mut statement = conn
        .prepare(
            "SELECT host_id, endpoint, certificate_fingerprint, credential_reference,
                    protocol_version, capabilities_json, repositories_json, capacity,
                    active_assignments, state
             FROM task_board_execution_hosts ORDER BY host_id",
        )
        .map_err(|error| db_error(format!("inspect legacy remote hosts: {error}")))?;
    let rows = statement
        .query_map([], decode_legacy_host)
        .map_err(|error| db_error(format!("read legacy remote hosts: {error}")))?;
    for row in rows {
        validate_legacy_host(
            row.map_err(|error| db_error(format!("decode legacy remote host evidence: {error}")))?,
            &configured_by_id,
        )?;
    }
    Ok(())
}

fn decode_legacy_host(row: &rusqlite::Row<'_>) -> rusqlite::Result<LegacyHostEvidence> {
    let capabilities_json: String = row.get(5)?;
    let repositories_json: String = row.get(6)?;
    Ok(LegacyHostEvidence {
        host_id: row.get(0)?,
        endpoint: row.get(1)?,
        certificate_fingerprint: row.get(2)?,
        credential_reference: row.get(3)?,
        protocol_version: row.get(4)?,
        capabilities: decode_json_column(&capabilities_json, 5)?,
        repositories: decode_json_column(&repositories_json, 6)?,
        capacity: row.get(7)?,
        active_assignments: row.get(8)?,
        state: row.get(9)?,
    })
}

fn decode_json_column(value: &str, index: usize) -> rusqlite::Result<Vec<String>> {
    serde_json::from_str(value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn validate_legacy_host(
    host: LegacyHostEvidence,
    configured: &BTreeMap<&str, &TaskBoardExecutionHostConfig>,
) -> Result<(), CliError> {
    let stored = TaskBoardExecutionHostConfig {
        host_id: host.host_id.clone(),
        endpoint: host.endpoint,
        certificate_fingerprint: host.certificate_fingerprint,
        credential_reference: host.credential_reference,
        enabled: true,
    };
    validate_migratable_host_config(&stored)?;
    let matches_operator = configured
        .get(stored.host_id.as_str())
        .is_some_and(|expected| {
            expected.endpoint == stored.endpoint
                && expected.certificate_fingerprint == stored.certificate_fingerprint
                && expected.credential_reference == stored.credential_reference
        });
    if !matches_operator {
        return Err(db_error(format!(
            "legacy remote host '{}' does not match operator-owned trust anchors",
            stored.host_id
        )));
    }
    validate_ordered_ids(&host.capabilities, "capability")?;
    validate_ordered_repositories(&host.repositories)?;
    if host.protocol_version != i64::from(TASK_BOARD_REMOTE_PROTOCOL_VERSION)
        || host.capacity <= 0
        || !(0..=host.capacity).contains(&host.active_assignments)
        || !matches!(host.state.as_str(), "healthy" | "degraded" | "unavailable")
    {
        return Err(db_error(format!(
            "legacy remote host '{}' has invalid observed evidence",
            stored.host_id
        )));
    }
    Ok(())
}

fn validate_migratable_host_configs(
    hosts: &[TaskBoardExecutionHostConfig],
) -> Result<(), CliError> {
    let normalized = hosts
        .iter()
        .map(normalize_migratable_host_config)
        .collect::<Vec<_>>();
    validate_execution_host_configs(&normalized)
}

fn validate_migratable_host_config(
    host: &TaskBoardExecutionHostConfig,
) -> Result<(), CliError> {
    validate_execution_host_config(&normalize_migratable_host_config(host))
}

fn normalize_migratable_host_config(
    host: &TaskBoardExecutionHostConfig,
) -> TaskBoardExecutionHostConfig {
    let mut normalized = host.clone();
    if is_legacy_leaf_fingerprint(&normalized.certificate_fingerprint) {
        normalized.certificate_fingerprint = remote_spki_pin::encode([0; 32]);
    }
    normalized
}

fn is_legacy_leaf_fingerprint(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn validate_ordered_ids(values: &[String], label: &str) -> Result<(), CliError> {
    if values.is_empty()
        || values.iter().any(|value| !is_canonical_id(value))
        || values.windows(2).any(|pair| pair[0] >= pair[1])
    {
        return Err(db_error(format!(
            "legacy remote host {label} inventory is invalid"
        )));
    }
    Ok(())
}

fn validate_ordered_repositories(values: &[String]) -> Result<(), CliError> {
    if values.is_empty()
        || values
            .iter()
            .any(|value| normalize_repository_slug(Some(value)).as_deref() != Some(value.as_str()))
        || values.windows(2).any(|pair| pair[0] >= pair[1])
    {
        return Err(db_error(
            "legacy remote host repository inventory is invalid",
        ));
    }
    Ok(())
}

fn is_canonical_id(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'-' | b'_' | b'.')
        })
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
        && !value.contains("..")
}
