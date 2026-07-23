use std::collections::BTreeMap;

use serde_json::json;
use sqlx::{Sqlite, Transaction, query, query_as};
use uuid::Uuid;

use super::items::{TaskBoardItemSnapshot, insert_item_in_tx, replace_item_in_tx};
use super::mapper::{item_from_rows, label};
use super::rows::{ExternalRefRow, ItemRow};
use crate::daemon::db::audit::upsert_audit_event_in_tx;
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::errors::CliErrorKind;
use crate::task_board::{
    TaskBoardItem, TaskBoardLaneOrigin, TaskBoardStatus, sort_task_board_items,
};

mod automatic;

#[derive(Debug, Clone)]
pub(crate) struct TaskBoardItemsSnapshot {
    pub(crate) items: Vec<TaskBoardItemSnapshot>,
    pub(crate) items_change_seq: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardLaneShift {
    pub(crate) item_id: String,
    pub(crate) item_revision: i64,
}

#[derive(Debug)]
pub(super) struct LaneTransitionWrite {
    pub(super) item: TaskBoardItem,
    pub(super) item_revision: i64,
    pub(super) shifted: Vec<TaskBoardLaneShift>,
    pub(super) changed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum LaneTransitionKind {
    Generic,
    Manual,
    Automatic,
    ProviderExclusionHide,
    ProviderExclusionRestore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardLanePositionAuditKind {
    Set,
    Reset,
}

pub(super) async fn insert_with_lane_transition_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: TaskBoardItem,
) -> Result<LaneTransitionWrite, CliError> {
    write_lane_transition_in_tx(transaction, None, item, 1, LaneTransitionKind::Generic).await
}

pub(super) async fn replace_with_lane_transition_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: TaskBoardItem,
    before_revision: i64,
    item: TaskBoardItem,
    transition: LaneTransitionKind,
) -> Result<LaneTransitionWrite, CliError> {
    let item_revision = next_item_revision(before_revision)?;
    write_lane_transition_in_tx(
        transaction,
        Some((before, before_revision)),
        item,
        item_revision,
        transition,
    )
    .await
}

fn next_item_revision(revision: i64) -> Result<i64, CliError> {
    revision
        .checked_add(1)
        .ok_or_else(|| db_error("task board item revision is out of range"))
}

pub(super) async fn record_lane_transition_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    write: &LaneTransitionWrite,
    items_change_seq: i64,
) -> Result<(), CliError> {
    if !write.changed {
        return Ok(());
    }
    let event = HarnessMonitorAuditEvent {
        id: format!("audit-{}", Uuid::new_v4().simple()),
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "task_board".into(),
        kind: "task_board.item.lane_position_changed".into(),
        severity: "info".into(),
        outcome: "success".into(),
        title: "Task Board lane position changed".into(),
        summary: format!("Updated lane placement for {}", write.item.id),
        subject: Some(write.item.id.clone()),
        actor: write.item.lane_origin.as_ref().and_then(|origin| {
            origin
                .actor()
                .or_else(|| origin.producer())
                .map(ToOwned::to_owned)
        }),
        correlation_id: None,
        action_key: Some("task_board.item.lane_position_changed".into()),
        payload_json: Some(json!({
            "item_id": write.item.id,
            "item_revision": write.item_revision,
            "items_change_seq": items_change_seq,
            "lane_position": write.item.lane_position,
            "shifted": write.shifted.iter().map(|shift| json!({
                "item_id": shift.item_id,
                "item_revision": shift.item_revision,
            })).collect::<Vec<_>>(),
        })),
        legacy_message: None,
        related_urls: Vec::new(),
    };
    upsert_audit_event_in_tx(transaction, &event).await
}

async fn write_lane_transition_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    before: Option<(TaskBoardItem, i64)>,
    mut item: TaskBoardItem,
    item_revision: i64,
    transition: LaneTransitionKind,
) -> Result<LaneTransitionWrite, CliError> {
    item.status = item.status.canonical_persisted_status();
    let preserves_manual_tombstone = transition == LaneTransitionKind::ProviderExclusionHide
        && item
            .lane_origin
            .as_ref()
            .is_some_and(TaskBoardLaneOrigin::is_manual);
    if item.deleted_at.is_some() && !preserves_manual_tombstone {
        clear_placement(&mut item);
    }
    let changed = lane_membership_changed(before.as_ref().map(|(item, _)| item), &item);
    if !changed {
        if before.is_some() {
            replace_item_in_tx(transaction, &item, item_revision).await?;
        } else {
            insert_item_in_tx(transaction, &item, item_revision).await?;
        }
        return Ok(LaneTransitionWrite {
            item,
            item_revision,
            shifted: Vec::new(),
            changed: false,
        });
    }

    let previous = before.as_ref().map(|(item, _)| item);
    if transition == LaneTransitionKind::Automatic
        && previous
            .and_then(|prior| prior.lane_origin.as_ref())
            .is_some_and(TaskBoardLaneOrigin::is_manual)
    {
        return Ok(LaneTransitionWrite {
            item: previous
                .cloned()
                .expect("automatic transition has prior item"),
            item_revision: before.as_ref().map_or(1, |(_, revision)| *revision),
            shifted: Vec::new(),
            changed: false,
        });
    }

    let allow_destination_clamp = allows_destination_clamp(previous, &item, transition);
    let source_status = previous
        .filter(|prior| prior.deleted_at.is_none())
        .map(|prior| prior.status.canonical_persisted_status());
    let destination_status = item
        .deleted_at
        .is_none()
        .then_some(item.status.canonical_persisted_status());
    let mut entries =
        load_lane_entries_in_tx(transaction, source_status, destination_status).await?;
    normalize_lane_entries(
        &mut entries,
        previous,
        &mut item,
        source_status,
        destination_status,
        transition,
        allow_destination_clamp,
    )?;

    let mut shifted = Vec::new();
    clear_changed_anchors_in_tx(transaction, &entries, previous, &item).await?;
    for entry in entries
        .iter_mut()
        .filter(|entry| entry.before != entry.item)
    {
        let item_revision = next_item_revision(entry.revision)?;
        replace_item_in_tx(transaction, &entry.item, item_revision).await?;
        shifted.push(TaskBoardLaneShift {
            item_id: entry.item.id.clone(),
            item_revision,
        });
    }
    let placement_changed = placement_changed(previous, &item, &shifted);
    match before {
        Some(_) => replace_item_in_tx(transaction, &item, item_revision).await?,
        None => insert_item_in_tx(transaction, &item, item_revision).await?,
    }
    shifted.retain(|shift| shift.item_id != item.id);
    Ok(LaneTransitionWrite {
        item,
        item_revision,
        shifted,
        changed: placement_changed,
    })
}

fn normalize_lane_entries(
    entries: &mut Vec<LaneEntry>,
    previous: Option<&TaskBoardItem>,
    item: &mut TaskBoardItem,
    source_status: Option<TaskBoardStatus>,
    destination_status: Option<TaskBoardStatus>,
    transition: LaneTransitionKind,
    allow_destination_clamp: bool,
) -> Result<(), CliError> {
    entries.retain(|entry| entry.before.id != item.id);
    if transition == LaneTransitionKind::Automatic {
        return automatic::normalize_transition(
            entries,
            previous,
            item,
            source_status,
            destination_status,
        );
    }
    if let Some(prior) = previous.filter(|prior| prior.deleted_at.is_none()) {
        let position =
            source_removal_position(source_status, destination_status, prior, item, entries);
        if let Some(position) = position {
            shift_left_after_removal(entries, prior.status, position);
        }
    }
    let unchanged_same_lane_position = source_status == destination_status
        && previous.is_some_and(|prior| prior.lane_position == item.lane_position);
    if let Some(status) = destination_status.filter(|_| !unchanged_same_lane_position) {
        place_in_destination(entries, item, status, transition, allow_destination_clamp)?;
    }
    Ok(())
}

fn source_removal_position(
    source_status: Option<TaskBoardStatus>,
    destination_status: Option<TaskBoardStatus>,
    prior: &TaskBoardItem,
    item: &TaskBoardItem,
    entries: &[LaneEntry],
) -> Option<u32> {
    let placement_changed =
        source_status != destination_status || prior.lane_position != item.lane_position;
    placement_changed
        .then(|| {
            prior
                .lane_position
                .or_else(|| default_position_before_removal(entries, prior))
        })
        .flatten()
}

fn placement_changed(
    previous: Option<&TaskBoardItem>,
    item: &TaskBoardItem,
    shifted: &[TaskBoardLaneShift],
) -> bool {
    if !shifted.is_empty() {
        return true;
    }
    let Some(previous) = previous else {
        return item.lane_position.is_some();
    };
    let placement_tuple_changed = previous.lane_position != item.lane_position
        || previous.lane_origin != item.lane_origin
        || previous.lane_set_at != item.lane_set_at;
    let membership_changed = previous.status.canonical_persisted_status()
        != item.status.canonical_persisted_status()
        || previous.deleted_at.is_some() != item.deleted_at.is_some();
    placement_tuple_changed
        || (membership_changed
            && (previous.lane_position.is_some() || item.lane_position.is_some()))
}

fn default_position_before_removal(entries: &[LaneEntry], prior: &TaskBoardItem) -> Option<u32> {
    let status = prior.status.canonical_persisted_status();
    let mut source = entries
        .iter()
        .filter(|entry| entry.item.status == status)
        .map(|entry| entry.item.clone())
        .collect::<Vec<_>>();
    source.push(prior.clone());
    sort_task_board_items(&mut source);
    source
        .iter()
        .position(|item| item.id == prior.id)
        .and_then(|position| u32::try_from(position).ok())
}

fn lane_membership_changed(before: Option<&TaskBoardItem>, item: &TaskBoardItem) -> bool {
    let Some(before) = before else {
        return item.lane_position.is_some();
    };
    before.status.canonical_persisted_status() != item.status.canonical_persisted_status()
        || before.deleted_at.is_some() != item.deleted_at.is_some()
        || before.lane_position != item.lane_position
        || before.lane_origin != item.lane_origin
        || before.lane_set_at != item.lane_set_at
}

fn is_generic_cross_lane_placement(
    previous: Option<&TaskBoardItem>,
    item: &TaskBoardItem,
    transition: LaneTransitionKind,
) -> bool {
    let Some(previous) = previous else {
        return false;
    };
    transition == LaneTransitionKind::Generic
        && previous.status.canonical_persisted_status() != item.status.canonical_persisted_status()
        && previous.lane_position.is_some()
        && item.lane_position == previous.lane_position
        && item.lane_origin == previous.lane_origin
        && item.lane_set_at == previous.lane_set_at
}

fn allows_destination_clamp(
    previous: Option<&TaskBoardItem>,
    item: &TaskBoardItem,
    transition: LaneTransitionKind,
) -> bool {
    transition == LaneTransitionKind::ProviderExclusionRestore
        || is_generic_cross_lane_placement(previous, item, transition)
}

fn shift_left_after_removal(entries: &mut [LaneEntry], status: TaskBoardStatus, position: u32) {
    for entry in entries {
        if entry.item.status == status
            && entry
                .item
                .lane_position
                .is_some_and(|current| current > position)
        {
            entry.item.lane_position = entry.item.lane_position.map(|current| current - 1);
        }
    }
}

fn place_in_destination(
    entries: &mut [LaneEntry],
    item: &mut TaskBoardItem,
    status: TaskBoardStatus,
    transition: LaneTransitionKind,
    allow_destination_clamp: bool,
) -> Result<(), CliError> {
    let destination_count = entries
        .iter()
        .filter(|entry| entry.item.status == status && entry.item.deleted_at.is_none())
        .count();
    let max_position = u32::try_from(destination_count).map_err(|_| {
        CliErrorKind::task_board_lane_capacity("lane cardinality exceeds u32 position capacity")
    })?;
    let Some(mut requested) = item.lane_position else {
        return Ok(());
    };
    if requested > max_position {
        if allow_destination_clamp {
            requested = max_position;
            item.lane_position = Some(requested);
        } else {
            return Err(CliErrorKind::task_board_lane_capacity(format!(
                "position {requested} is outside lane cardinality {destination_count}"
            ))
            .into());
        }
    }
    debug_assert_ne!(transition, LaneTransitionKind::Automatic);
    for entry in entries {
        if entry.item.status == status
            && entry
                .item
                .lane_position
                .is_some_and(|current| current >= requested)
        {
            entry.item.lane_position = entry
                .item
                .lane_position
                .map(|current| {
                    current.checked_add(1).ok_or_else(|| {
                        CliErrorKind::task_board_lane_capacity(
                            "lane anchor position cannot be shifted beyond u32::MAX",
                        )
                    })
                })
                .transpose()?;
        }
    }
    Ok(())
}

async fn clear_changed_anchors_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    entries: &[LaneEntry],
    previous: Option<&TaskBoardItem>,
    item: &TaskBoardItem,
) -> Result<(), CliError> {
    let mut ids = entries
        .iter()
        .filter(|entry| entry.before != entry.item && entry.before.lane_position.is_some())
        .map(|entry| entry.before.id.as_str())
        .collect::<Vec<_>>();
    if previous.is_some_and(|prior| prior.lane_position.is_some()) {
        ids.push(item.id.as_str());
    }
    for item_id in ids {
        query("UPDATE task_board_items SET lane_position = NULL, lane_origin = NULL, lane_actor = NULL, lane_producer = NULL, lane_set_at = NULL WHERE item_id = ?1")
            .bind(item_id)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("clear task-board lane placement '{item_id}': {error}")))?;
    }
    Ok(())
}

#[derive(Debug)]
pub(super) struct LaneEntry {
    before: TaskBoardItem,
    pub(super) item: TaskBoardItem,
    revision: i64,
}

pub(super) async fn load_lane_entries_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    source: Option<TaskBoardStatus>,
    destination: Option<TaskBoardStatus>,
) -> Result<Vec<LaneEntry>, CliError> {
    let mut statuses = Vec::new();
    for status in [source, destination].into_iter().flatten() {
        if !statuses.contains(&status) {
            statuses.push(status);
        }
    }
    if statuses.is_empty() {
        return Ok(Vec::new());
    }
    let first = label(statuses[0], "task-board lane status")?;
    let second = label(
        *statuses.get(1).unwrap_or(&statuses[0]),
        "task-board lane status",
    )?;
    let rows = query_as::<_, ItemRow>(
        "SELECT * FROM task_board_items
         WHERE deleted_at IS NULL AND (status = ?1 OR status = ?2)",
    )
    .bind(&first)
    .bind(&second)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task-board lane rows: {error}")))?;
    let refs = query_as::<_, ExternalRefRow>(
        "SELECT refs.item_id, refs.position, refs.provider, refs.external_id, refs.url,
                refs.sync_state_json
         FROM task_board_external_refs AS refs
         INNER JOIN task_board_items AS items ON items.item_id = refs.item_id
         WHERE items.deleted_at IS NULL AND (items.status = ?1 OR items.status = ?2)
         ORDER BY refs.item_id, refs.position",
    )
    .bind(&first)
    .bind(&second)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task-board lane refs: {error}")))?;
    let mut refs_by_item = BTreeMap::<String, Vec<ExternalRefRow>>::new();
    for reference in refs {
        refs_by_item
            .entry(reference.item_id.clone())
            .or_default()
            .push(reference);
    }
    let mut entries = Vec::with_capacity(rows.len());
    for row in rows {
        let refs = refs_by_item.remove(&row.item_id).unwrap_or_default();
        let (item, revision) = item_from_rows(row, refs)?;
        entries.push(LaneEntry {
            before: item.clone(),
            item,
            revision,
        });
    }
    Ok(entries)
}

fn clear_placement(item: &mut TaskBoardItem) {
    item.lane_position = None;
    item.lane_origin = None;
    item.lane_set_at = None;
}
