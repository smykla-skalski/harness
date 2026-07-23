use std::collections::BTreeMap;

use super::LaneEntry;
use crate::daemon::db::{CliError, db_error};
use crate::errors::CliErrorKind;
use crate::task_board::{
    TaskBoardItem, TaskBoardLaneOrigin, TaskBoardStatus, sort_task_board_items,
};

pub(super) fn normalize_transition(
    entries: &mut [LaneEntry],
    previous: Option<&TaskBoardItem>,
    item: &mut TaskBoardItem,
    source_status: Option<TaskBoardStatus>,
    destination_status: Option<TaskBoardStatus>,
) -> Result<(), CliError> {
    if source_status == destination_status {
        return normalize_same_lane(entries, previous, item, destination_status);
    }
    if let Some(status) = source_status {
        let mut order = materialized_order(entries, status, previous);
        order.retain(|candidate| candidate.id != item.id);
        apply_order(entries, item, status, &order)?;
    }
    if let Some(status) = destination_status {
        let order = materialized_order(entries, status, None);
        apply_destination(entries, item, status, order)?;
    }
    Ok(())
}

fn normalize_same_lane(
    entries: &mut [LaneEntry],
    previous: Option<&TaskBoardItem>,
    item: &mut TaskBoardItem,
    status: Option<TaskBoardStatus>,
) -> Result<(), CliError> {
    let Some(status) = status else {
        return Ok(());
    };
    if previous.is_some_and(|prior| prior.lane_position == item.lane_position) {
        return Ok(());
    }
    let mut order = materialized_order(entries, status, previous);
    order.retain(|candidate| candidate.id != item.id);
    apply_destination(entries, item, status, order)
}

fn materialized_order(
    entries: &[LaneEntry],
    status: TaskBoardStatus,
    previous: Option<&TaskBoardItem>,
) -> Vec<TaskBoardItem> {
    let mut items = entries
        .iter()
        .filter(|entry| entry.item.status.canonical_persisted_status() == status)
        .map(|entry| entry.item.clone())
        .collect::<Vec<_>>();
    if let Some(previous) = previous.filter(|previous| {
        !previous.is_deleted() && previous.status.canonical_persisted_status() == status
    }) {
        items.push(previous.clone());
    }
    sort_task_board_items(&mut items);
    items
}

fn apply_destination(
    entries: &mut [LaneEntry],
    item: &mut TaskBoardItem,
    status: TaskBoardStatus,
    mut order: Vec<TaskBoardItem>,
) -> Result<(), CliError> {
    let Some(requested) = item.lane_position else {
        order.push(item.clone());
        sort_task_board_items(&mut order);
        return apply_order(entries, item, status, &order);
    };
    let final_count = order
        .len()
        .checked_add(1)
        .ok_or_else(|| lane_capacity("lane cardinality exceeds position capacity"))?;
    let requested = usize::try_from(requested)
        .map_err(|_| lane_capacity("requested lane position exceeds platform capacity"))?;
    if requested >= final_count {
        return Err(lane_capacity(format!(
            "position {requested} is outside lane cardinality {final_count}"
        )));
    }
    let manuals = adjusted_manual_slots(&order, final_count)?;
    let available = available_slots(final_count, &manuals);
    let insertion = available
        .partition_point(|position| *position < requested)
        .min(available.len().saturating_sub(1));
    let mut non_manual = order
        .into_iter()
        .filter(|candidate| !is_manual(candidate))
        .collect::<Vec<_>>();
    non_manual.insert(insertion, item.clone());
    apply_layout(entries, item, status, manuals, &non_manual)
}

fn apply_order(
    entries: &mut [LaneEntry],
    item: &mut TaskBoardItem,
    status: TaskBoardStatus,
    order: &[TaskBoardItem],
) -> Result<(), CliError> {
    let manuals = adjusted_manual_slots(order, order.len())?;
    let non_manual = order
        .iter()
        .filter(|candidate| !is_manual(candidate))
        .cloned()
        .collect::<Vec<_>>();
    apply_layout(entries, item, status, manuals, &non_manual)
}

fn adjusted_manual_slots(
    order: &[TaskBoardItem],
    count: usize,
) -> Result<BTreeMap<usize, String>, CliError> {
    let mut anchors = order
        .iter()
        .filter(|item| is_manual(item))
        .map(|item| {
            item.lane_position
                .and_then(|position| usize::try_from(position).ok())
                .map(|position| (position, item.id.clone()))
                .ok_or_else(|| db_error("manual lane anchor has no valid position"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    anchors.sort();
    if anchors.len() > count {
        return Err(db_error("manual lane anchors exceed lane cardinality"));
    }
    let mut slots = BTreeMap::new();
    let mut minimum = 0;
    let anchor_count = anchors.len();
    for (offset, (requested, item_id)) in anchors.into_iter().enumerate() {
        let remaining = anchor_count - offset;
        let maximum = count - remaining;
        let slot = requested.clamp(minimum, maximum);
        slots.insert(slot, item_id);
        minimum = slot + 1;
    }
    Ok(slots)
}

fn available_slots(count: usize, manuals: &BTreeMap<usize, String>) -> Vec<usize> {
    (0..count)
        .filter(|position| !manuals.contains_key(position))
        .collect()
}

fn apply_layout(
    entries: &mut [LaneEntry],
    item: &mut TaskBoardItem,
    status: TaskBoardStatus,
    manuals: BTreeMap<usize, String>,
    non_manual: &[TaskBoardItem],
) -> Result<(), CliError> {
    let count = manuals.len() + non_manual.len();
    let mut non_manual = non_manual.iter();
    let mut positions = BTreeMap::new();
    for position in 0..count {
        let item_id = manuals
            .get(&position)
            .map(String::as_str)
            .or_else(|| non_manual.next().map(|candidate| candidate.id.as_str()))
            .ok_or_else(|| db_error("automatic lane layout has an empty slot"))?;
        let position = u32::try_from(position)
            .map_err(|_| lane_capacity("lane cardinality exceeds u32 position capacity"))?;
        positions.insert(item_id.to_string(), position);
    }
    if non_manual.next().is_some() {
        return Err(db_error("automatic lane layout has excess items"));
    }
    for entry in entries
        .iter_mut()
        .filter(|entry| entry.item.status.canonical_persisted_status() == status)
    {
        apply_explicit_position(&mut entry.item, &positions)?;
    }
    if item.status.canonical_persisted_status() == status {
        apply_explicit_position(item, &positions)?;
    }
    Ok(())
}

fn apply_explicit_position(
    item: &mut TaskBoardItem,
    positions: &BTreeMap<String, u32>,
) -> Result<(), CliError> {
    if item.lane_origin.is_none() {
        return Ok(());
    }
    item.lane_position = Some(
        positions
            .get(&item.id)
            .copied()
            .ok_or_else(|| db_error("automatic lane layout omitted an explicit item"))?,
    );
    Ok(())
}

fn is_manual(item: &TaskBoardItem) -> bool {
    item.lane_origin
        .as_ref()
        .is_some_and(TaskBoardLaneOrigin::is_manual)
}

fn lane_capacity(message: impl Into<String>) -> CliError {
    CliErrorKind::task_board_lane_capacity(message.into()).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::TaskBoardPriority;

    const NOW: &str = "2026-07-23T08:00:00Z";

    #[test]
    fn automatic_insert_resequences_automatic_cards_around_manual_anchor() {
        let mut entries = vec![
            entry(manual("manual", 0)),
            entry(automatic("low", 1, TaskBoardPriority::Low)),
        ];
        let previous = default("candidate", TaskBoardPriority::High);
        let mut candidate = automatic("candidate", 1, TaskBoardPriority::High);

        normalize_transition(
            &mut entries,
            Some(&previous),
            &mut candidate,
            Some(TaskBoardStatus::Todo),
            Some(TaskBoardStatus::Todo),
        )
        .expect("normalize automatic insert");

        assert_eq!(position(&entries, "manual"), 0);
        assert_eq!(candidate.lane_position, Some(1));
        assert_eq!(position(&entries, "low"), 2);
    }

    #[test]
    fn automatic_rerank_resequences_existing_automatic_cards() {
        let previous = automatic("candidate", 3, TaskBoardPriority::Low);
        let mut entries = vec![
            entry(manual("manual", 0)),
            entry(automatic("medium", 1, TaskBoardPriority::Medium)),
            entry(automatic("low", 2, TaskBoardPriority::Low)),
        ];
        let mut candidate = automatic("candidate", 1, TaskBoardPriority::Critical);

        normalize_transition(
            &mut entries,
            Some(&previous),
            &mut candidate,
            Some(TaskBoardStatus::Todo),
            Some(TaskBoardStatus::Todo),
        )
        .expect("normalize automatic rerank");

        assert_eq!(position(&entries, "manual"), 0);
        assert_eq!(candidate.lane_position, Some(1));
        assert_eq!(position(&entries, "medium"), 2);
        assert_eq!(position(&entries, "low"), 3);
    }

    #[test]
    fn automatic_removal_keeps_valid_manual_slot_and_compacts_automatic_card() {
        let previous = automatic("removed", 0, TaskBoardPriority::High);
        let mut entries = vec![
            entry(default("default", TaskBoardPriority::Medium)),
            entry(manual("manual", 2)),
            entry(automatic("automatic", 3, TaskBoardPriority::Low)),
        ];
        let mut moved = previous.clone();
        moved.status = TaskBoardStatus::Backlog;
        moved.lane_position = None;
        moved.lane_origin = None;
        moved.lane_set_at = None;

        normalize_transition(
            &mut entries,
            Some(&previous),
            &mut moved,
            Some(TaskBoardStatus::Todo),
            Some(TaskBoardStatus::Backlog),
        )
        .expect("normalize automatic removal");

        assert_eq!(position(&entries, "automatic"), 1);
        assert_eq!(position(&entries, "manual"), 2);
        assert_eq!(moved.lane_position, None);
    }

    #[test]
    fn manual_tail_compacts_only_when_cardinality_requires_it() {
        let previous = automatic("removed", 0, TaskBoardPriority::High);
        let mut entries = vec![entry(manual("manual", 1))];
        let mut moved = previous.clone();
        moved.status = TaskBoardStatus::Backlog;
        moved.lane_position = None;
        moved.lane_origin = None;
        moved.lane_set_at = None;

        normalize_transition(
            &mut entries,
            Some(&previous),
            &mut moved,
            Some(TaskBoardStatus::Todo),
            Some(TaskBoardStatus::Backlog),
        )
        .expect("normalize required manual compaction");

        assert_eq!(position(&entries, "manual"), 0);
    }

    #[test]
    fn automatic_target_at_manual_tail_uses_last_available_slot() {
        let mut entries = vec![entry(manual("manual", 1))];
        let previous = default("candidate", TaskBoardPriority::High);
        let mut candidate = automatic("candidate", 1, TaskBoardPriority::High);

        normalize_transition(
            &mut entries,
            Some(&previous),
            &mut candidate,
            Some(TaskBoardStatus::Todo),
            Some(TaskBoardStatus::Todo),
        )
        .expect("place before a manual tail");

        assert_eq!(candidate.lane_position, Some(0));
        assert_eq!(position(&entries, "manual"), 1);
    }

    fn entry(item: TaskBoardItem) -> LaneEntry {
        LaneEntry {
            before: item.clone(),
            item,
            revision: 1,
        }
    }

    fn default(id: &str, priority: TaskBoardPriority) -> TaskBoardItem {
        let mut item = TaskBoardItem::new(id.into(), id.into(), String::new(), NOW.into());
        item.priority = priority;
        item
    }

    fn automatic(id: &str, position: u32, priority: TaskBoardPriority) -> TaskBoardItem {
        let mut item = default(id, priority);
        item.lane_position = Some(position);
        item.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
            producer: "test".into(),
        });
        item.lane_set_at = Some(NOW.into());
        item
    }

    fn manual(id: &str, position: u32) -> TaskBoardItem {
        let mut item = default(id, TaskBoardPriority::Medium);
        item.lane_position = Some(position);
        item.lane_origin = Some(TaskBoardLaneOrigin::Manual {
            actor: "user".into(),
        });
        item.lane_set_at = Some(NOW.into());
        item
    }

    fn position(entries: &[LaneEntry], id: &str) -> u32 {
        entries
            .iter()
            .find(|entry| entry.item.id == id)
            .and_then(|entry| entry.item.lane_position)
            .expect("explicit position")
    }
}
