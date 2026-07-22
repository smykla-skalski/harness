use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use super::rows::{ExternalRefRow, ItemRow, MachineRow};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    ExternalRef, Machine, TaskBoardItem, TaskBoardLaneOrigin, validate_lane_placement,
};

pub(super) fn item_from_rows(
    row: ItemRow,
    external_refs: Vec<ExternalRefRow>,
) -> Result<(TaskBoardItem, i64), CliError> {
    let revision = row.revision;
    let schema_version = u32::try_from(row.schema_version)
        .map_err(|error| db_error(format!("parse task board schema version: {error}")))?;
    let lane_position = optional_u32(row.lane_position, "task board lane position")?;
    let lane_origin = lane_origin_from_row(&row)?;
    let lane_set_at = row.lane_set_at.clone();
    let item = TaskBoardItem {
        schema_version,
        id: row.item_id,
        title: row.title,
        body: row.body,
        status: parse_label(&row.status, "task board status")?,
        priority: parse_label(&row.priority, "task board priority")?,
        tags: parse_json(&row.tags_json, "task board tags")?,
        project_id: row.project_id,
        target_project_types: parse_json(
            &row.target_project_types_json,
            "task board project types",
        )?,
        agent_mode: parse_label(&row.agent_mode, "task board agent mode")?,
        workflow_kind: parse_label(&row.workflow_kind, "task board workflow kind")?,
        kind: parse_label(&row.kind, "task board kind")?,
        execution_repository: row.execution_repository,
        estimated_tokens: optional_u64(row.estimated_tokens, "task board estimated tokens")?,
        estimated_cost_microusd: optional_u64(
            row.estimated_cost_microusd,
            "task board estimated cost",
        )?,
        external_refs: external_refs
            .into_iter()
            .map(external_ref_from_row)
            .collect::<Result<Vec<_>, _>>()?,
        imported_from_provider: row
            .imported_from_provider
            .as_deref()
            .map(|value| parse_label(value, "task board imported provider"))
            .transpose()?,
        planning: parse_json(&row.planning_json, "task board planning state")?,
        workflow: parse_json(&row.workflow_json, "task board workflow state")?,
        session_id: row.session_id,
        work_item_id: row.work_item_id,
        usage: parse_json(&row.usage_json, "task board usage")?,
        parent_item_id: row.parent_item_id,
        child_order: u32::try_from(row.child_order)
            .map_err(|error| db_error(format!("parse task board child order: {error}")))?,
        lane_position,
        lane_origin,
        lane_set_at,
        created_at: row.created_at,
        updated_at: row.updated_at,
        deleted_at: row.deleted_at,
    };
    validate_lane_placement(&item).map_err(db_error)?;
    Ok((item, revision))
}

fn lane_origin_from_row(row: &ItemRow) -> Result<Option<TaskBoardLaneOrigin>, CliError> {
    match (
        row.lane_origin.as_deref(),
        row.lane_actor.as_deref(),
        row.lane_producer.as_deref(),
    ) {
        (None, None, None) => Ok(None),
        (Some("manual"), Some(actor), None) => Ok(Some(TaskBoardLaneOrigin::Manual {
            actor: actor.to_owned(),
        })),
        (Some("automatic"), None, Some(producer)) => Ok(Some(TaskBoardLaneOrigin::Automatic {
            producer: producer.to_owned(),
        })),
        _ => Err(db_error(format!(
            "parse task board lane provenance: origin={}, actor={}, producer={}",
            lane_origin_state(row.lane_origin.as_deref()),
            optional_text_state(row.lane_actor.as_deref()),
            optional_text_state(row.lane_producer.as_deref())
        ))),
    }
}

fn lane_origin_state(value: Option<&str>) -> &'static str {
    match value {
        None => "missing",
        Some("manual") => "manual",
        Some("automatic") => "automatic",
        Some(_) => "unsupported",
    }
}

fn optional_text_state(value: Option<&str>) -> &'static str {
    match value {
        None => "missing",
        Some(value) if value.trim().is_empty() => "empty",
        Some(_) => "present",
    }
}

pub(super) fn external_ref_from_row(row: ExternalRefRow) -> Result<ExternalRef, CliError> {
    let _ = (row.item_id, row.position);
    Ok(ExternalRef {
        provider: parse_label(&row.provider, "task board external provider")?,
        external_id: row.external_id,
        url: row.url,
        sync_state: row
            .sync_state_json
            .as_deref()
            .map(|value| parse_json(value, "task board external sync state"))
            .transpose()?,
    })
}

pub(super) fn machine_from_row(row: MachineRow) -> Result<Machine, CliError> {
    Ok(Machine {
        id: row.machine_id,
        label: row.label,
        project_types: parse_json(&row.project_types_json, "machine project types")?,
        agent_modes: parse_json(&row.agent_modes_json, "machine agent modes")?,
        last_seen: row.last_seen,
    })
}

pub(super) fn to_json<T: Serialize>(value: &T, context: &str) -> Result<String, CliError> {
    serde_json::to_string(value).map_err(|error| db_error(format!("serialize {context}: {error}")))
}

pub(super) fn parse_json<T: DeserializeOwned>(value: &str, context: &str) -> Result<T, CliError> {
    serde_json::from_str(value).map_err(|error| db_error(format!("parse {context}: {error}")))
}

pub(super) fn label<T: Serialize>(value: T, context: &str) -> Result<String, CliError> {
    serde_json::to_value(value)
        .map_err(|error| db_error(format!("serialize {context}: {error}")))?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| db_error(format!("serialize {context}: expected string")))
}

fn parse_label<T: DeserializeOwned>(value: &str, context: &str) -> Result<T, CliError> {
    serde_json::from_value(Value::String(value.to_owned()))
        .map_err(|error| db_error(format!("parse {context}: {error}")))
}

fn optional_u64(value: Option<i64>, context: &str) -> Result<Option<u64>, CliError> {
    value
        .map(|value| {
            u64::try_from(value).map_err(|error| db_error(format!("parse {context}: {error}")))
        })
        .transpose()
}

fn optional_u32(value: Option<i64>, context: &str) -> Result<Option<u32>, CliError> {
    value
        .map(|value| {
            u32::try_from(value).map_err(|error| db_error(format!("parse {context}: {error}")))
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use super::{lane_origin_state, optional_text_state};

    #[test]
    fn lane_provenance_diagnostics_classify_without_echoing_values() {
        assert_eq!(lane_origin_state(Some("unexpected-origin")), "unsupported");
        assert_eq!(optional_text_state(Some("sensitive-actor")), "present");
    }
}
