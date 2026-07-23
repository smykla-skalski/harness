use sqlx::{Sqlite, Transaction, query};

use super::super::mapper::{label, to_json};
use super::validate_item;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{TaskBoardItem, TaskBoardLaneOrigin, TaskBoardTombstoneCause};

pub(crate) async fn insert_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    revision: i64,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_items (
        item_id, schema_version, title, body, status, priority, tags_json, project_id,
        target_project_types_json, agent_mode, workflow_kind, execution_repository,
        estimated_tokens, estimated_cost_microusd, imported_from_provider, planning_json,
        workflow_json, session_id, work_item_id, usage_json, parent_item_id, child_order,
        created_at, updated_at, deleted_at, revision, kind, lane_position, lane_origin,
        lane_actor, lane_producer, lane_set_at, tombstone_cause
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
        ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28,
        ?29, ?30, ?31, ?32, ?33)",
    )
    .bind(&item.id)
    .bind(i64::from(item.schema_version))
    .bind(&item.title)
    .bind(&item.body)
    .bind(label(item.status, "task board status")?)
    .bind(label(item.priority, "task board priority")?)
    .bind(to_json(&item.tags, "task board tags")?)
    .bind(&item.project_id)
    .bind(to_json(
        &item.target_project_types,
        "task board project types",
    )?)
    .bind(label(item.agent_mode, "task board agent mode")?)
    .bind(label(item.workflow_kind, "task board workflow kind")?)
    .bind(&item.execution_repository)
    .bind(optional_u64_as_i64(
        item.estimated_tokens,
        "task board estimated tokens",
    )?)
    .bind(optional_u64_as_i64(
        item.estimated_cost_microusd,
        "task board estimated cost",
    )?)
    .bind(
        item.imported_from_provider
            .map(|provider| label(provider, "task board imported provider"))
            .transpose()?,
    )
    .bind(to_json(&item.planning, "task board planning state")?)
    .bind(to_json(&item.workflow, "task board workflow state")?)
    .bind(&item.session_id)
    .bind(&item.work_item_id)
    .bind(to_json(&item.usage, "task board usage")?)
    .bind(&item.parent_item_id)
    .bind(i64::from(item.child_order))
    .bind(&item.created_at)
    .bind(&item.updated_at)
    .bind(&item.deleted_at)
    .bind(revision)
    .bind(label(item.kind.clone(), "task board kind")?)
    .bind(item.lane_position.map(i64::from))
    .bind(lane_origin_label(item.lane_origin.as_ref()))
    .bind(lane_actor(item.lane_origin.as_ref()))
    .bind(lane_producer(item.lane_origin.as_ref()))
    .bind(&item.lane_set_at)
    .bind(tombstone_cause_label(item.tombstone_cause.as_ref()))
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert task board item '{}': {error}", item.id)))?;
    insert_refs(transaction, item).await
}

pub(crate) async fn replace_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    revision: i64,
) -> Result<(), CliError> {
    validate_item(item)?;
    query(
        "UPDATE task_board_items SET
        schema_version = ?2, title = ?3, body = ?4, status = ?5, priority = ?6,
        tags_json = ?7, project_id = ?8, target_project_types_json = ?9,
        agent_mode = ?10, workflow_kind = ?11, execution_repository = ?12,
        estimated_tokens = ?13, estimated_cost_microusd = ?14,
        imported_from_provider = ?15, planning_json = ?16, workflow_json = ?17,
        session_id = ?18, work_item_id = ?19, usage_json = ?20, parent_item_id = ?21,
        child_order = ?22, created_at = ?23, updated_at = ?24, deleted_at = ?25,
        revision = ?26, kind = ?27, lane_position = ?28, lane_origin = ?29,
        lane_actor = ?30, lane_producer = ?31, lane_set_at = ?32, tombstone_cause = ?33
        WHERE item_id = ?1",
    )
    .bind(&item.id)
    .bind(i64::from(item.schema_version))
    .bind(&item.title)
    .bind(&item.body)
    .bind(label(item.status, "task board status")?)
    .bind(label(item.priority, "task board priority")?)
    .bind(to_json(&item.tags, "task board tags")?)
    .bind(&item.project_id)
    .bind(to_json(
        &item.target_project_types,
        "task board project types",
    )?)
    .bind(label(item.agent_mode, "task board agent mode")?)
    .bind(label(item.workflow_kind, "task board workflow kind")?)
    .bind(&item.execution_repository)
    .bind(optional_u64_as_i64(
        item.estimated_tokens,
        "task board estimated tokens",
    )?)
    .bind(optional_u64_as_i64(
        item.estimated_cost_microusd,
        "task board estimated cost",
    )?)
    .bind(
        item.imported_from_provider
            .map(|provider| label(provider, "task board imported provider"))
            .transpose()?,
    )
    .bind(to_json(&item.planning, "task board planning state")?)
    .bind(to_json(&item.workflow, "task board workflow state")?)
    .bind(&item.session_id)
    .bind(&item.work_item_id)
    .bind(to_json(&item.usage, "task board usage")?)
    .bind(&item.parent_item_id)
    .bind(i64::from(item.child_order))
    .bind(&item.created_at)
    .bind(&item.updated_at)
    .bind(&item.deleted_at)
    .bind(revision)
    .bind(label(item.kind.clone(), "task board kind")?)
    .bind(item.lane_position.map(i64::from))
    .bind(lane_origin_label(item.lane_origin.as_ref()))
    .bind(lane_actor(item.lane_origin.as_ref()))
    .bind(lane_producer(item.lane_origin.as_ref()))
    .bind(&item.lane_set_at)
    .bind(tombstone_cause_label(item.tombstone_cause.as_ref()))
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("replace task board item '{}': {error}", item.id)))?;
    query("DELETE FROM task_board_external_refs WHERE item_id = ?1")
        .bind(&item.id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("clear task board refs '{}': {error}", item.id)))?;
    insert_refs(transaction, item).await
}

async fn insert_refs(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
) -> Result<(), CliError> {
    for (position, reference) in item.external_refs.iter().enumerate() {
        query(
            "INSERT INTO task_board_external_refs (
            item_id, position, provider, external_id, url, sync_state_json
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(&item.id)
        .bind(i64::try_from(position).unwrap_or(i64::MAX))
        .bind(label(reference.provider, "task board external provider")?)
        .bind(&reference.external_id)
        .bind(&reference.url)
        .bind(
            reference
                .sync_state
                .as_ref()
                .map(|state| to_json(state, "task board external sync state"))
                .transpose()?,
        )
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert task board refs '{}': {error}", item.id)))?;
    }
    Ok(())
}

fn lane_origin_label(origin: Option<&TaskBoardLaneOrigin>) -> Option<&'static str> {
    match origin {
        Some(TaskBoardLaneOrigin::Manual { .. }) => Some("manual"),
        Some(TaskBoardLaneOrigin::Automatic { .. }) => Some("automatic"),
        None => None,
    }
}

fn lane_actor(origin: Option<&TaskBoardLaneOrigin>) -> Option<&str> {
    origin.and_then(TaskBoardLaneOrigin::actor)
}

fn lane_producer(origin: Option<&TaskBoardLaneOrigin>) -> Option<&str> {
    origin.and_then(TaskBoardLaneOrigin::producer)
}

pub(super) fn tombstone_cause_label(
    cause: Option<&TaskBoardTombstoneCause>,
) -> Option<&'static str> {
    match cause {
        Some(TaskBoardTombstoneCause::Manual) => Some("manual"),
        Some(TaskBoardTombstoneCause::ProviderExclusion) => Some("provider_exclusion"),
        None => None,
    }
}

fn optional_u64_as_i64(value: Option<u64>, context: &str) -> Result<Option<i64>, CliError> {
    value
        .map(|value| {
            i64::try_from(value).map_err(|error| db_error(format!("store {context}: {error}")))
        })
        .transpose()
}
