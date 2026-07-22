use std::cmp::Ordering;
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::types::{TaskBoardItem, TaskBoardStatus};

const MAX_LANE_PROVENANCE_ID_BYTES: usize = 256;
const MAX_LANE_SET_AT_BYTES: usize = 128;

/// Provenance for an explicit lane position. Defaults intentionally have no
/// provenance because their visual slot is derived at read time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TaskBoardLaneOrigin {
    Manual { actor: String },
    Automatic { producer: String },
}

impl TaskBoardLaneOrigin {
    #[must_use]
    pub const fn is_manual(&self) -> bool {
        matches!(self, Self::Manual { .. })
    }

    #[must_use]
    pub fn actor(&self) -> Option<&str> {
        match self {
            Self::Manual { actor } => Some(actor),
            Self::Automatic { .. } => None,
        }
    }

    #[must_use]
    pub fn producer(&self) -> Option<&str> {
        match self {
            Self::Manual { .. } => None,
            Self::Automatic { producer } => Some(producer),
        }
    }
}

/// Validate the all-or-nothing explicit-position representation.
///
/// # Errors
///
/// Returns a static explanation when placement or provenance is incomplete or malformed.
pub fn validate_lane_placement(item: &TaskBoardItem) -> Result<(), &'static str> {
    match (&item.lane_position, &item.lane_origin, &item.lane_set_at) {
        (None, None, None) => Ok(()),
        (Some(_), Some(origin), Some(set_at)) if valid_set_at(set_at) => match origin {
            TaskBoardLaneOrigin::Manual { actor } if valid_provenance_id(actor) => Ok(()),
            TaskBoardLaneOrigin::Automatic { producer } if valid_provenance_id(producer) => Ok(()),
            TaskBoardLaneOrigin::Manual { .. } => Err("manual lane position actor is empty"),
            TaskBoardLaneOrigin::Automatic { .. } => {
                Err("automatic lane position producer is empty")
            }
        },
        _ => Err("lane position, origin, and set_at must be present together"),
    }
}

/// Reject persisted anchors that cannot occupy a distinct live lane slot.
///
/// # Errors
///
/// Returns a static explanation when a live lane has duplicate or out-of-range anchors.
pub fn validate_task_board_lane_order(items: &[TaskBoardItem]) -> Result<(), &'static str> {
    let mut lanes = BTreeMap::<TaskBoardStatus, Vec<&TaskBoardItem>>::new();
    for item in items.iter().filter(|item| !item.is_deleted()) {
        validate_lane_placement(item)?;
        lanes
            .entry(item.status.canonical_persisted_status())
            .or_default()
            .push(item);
    }
    for lane in lanes.into_values() {
        let mut occupied = BTreeMap::new();
        for item in lane.iter().filter(|item| item.lane_position.is_some()) {
            let Some(position) = item.lane_position else {
                continue;
            };
            if usize::try_from(position).ok().is_none_or(|position| position >= lane.len()) {
                return Err("lane position is outside the live lane cardinality");
            }
            if occupied.insert(position, item.id.as_str()).is_some() {
                return Err("lane positions must be unique within a live lane");
            }
        }
    }
    Ok(())
}

fn valid_set_at(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= MAX_LANE_SET_AT_BYTES
        && !value.chars().any(char::is_control)
}

fn valid_provenance_id(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= MAX_LANE_PROVENANCE_ID_BYTES
        && !value.chars().any(char::is_control)
}

/// Sort items by status and the one materialized ordering for each live lane.
///
/// All-default boards deliberately retain the legacy byte-for-byte comparator.
pub fn sort_task_board_items(items: &mut [TaskBoardItem]) {
    if items.iter().all(|item| item.lane_position.is_none()) {
        items.sort_by(legacy_item_order);
        return;
    }

    items.sort_by_key(|item| item.status);
    let mut start = 0;
    while start < items.len() {
        let status = items[start].status;
        let mut end = start + 1;
        while end < items.len() && items[end].status == status {
            end += 1;
        }
        order_status_group(&mut items[start..end], status);
        start = end;
    }
}

fn order_status_group(items: &mut [TaskBoardItem], _status: TaskBoardStatus) {
    let mut live = items
        .iter()
        .filter(|item| !item.is_deleted())
        .cloned()
        .collect::<Vec<_>>();
    let mut deleted = items
        .iter()
        .filter(|item| item.is_deleted())
        .cloned()
        .collect::<Vec<_>>();
    deleted.sort_by(legacy_item_order);
    materialize_lane_slots(&mut live).unwrap_or_else(|| live.sort_by(legacy_item_order));
    live.extend(deleted);
    items.clone_from_slice(&live);
}

fn materialize_lane_slots(items: &mut Vec<TaskBoardItem>) -> Option<()> {
    let count = items.len();
    let mut anchors = BTreeMap::<usize, TaskBoardItem>::new();
    let mut defaults = Vec::new();
    for item in items.drain(..) {
        if let Some(position) = item.lane_position {
            let position = usize::try_from(position).ok()?;
            if position >= count || anchors.insert(position, item).is_some() {
                return None;
            }
        } else {
            defaults.push(item);
        }
    }
    defaults.sort_by(legacy_within_lane_order);
    let mut default_items = defaults.into_iter();
    let mut ordered = Vec::with_capacity(count);
    for slot in 0..count {
        if let Some(item) = anchors.remove(&slot) {
            ordered.push(item);
        } else {
            ordered.push(default_items.next()?);
        }
    }
    *items = ordered;
    Some(())
}

fn legacy_item_order(left: &TaskBoardItem, right: &TaskBoardItem) -> Ordering {
    left.status
        .cmp(&right.status)
        .then_with(|| legacy_within_lane_order(left, right))
}

fn legacy_within_lane_order(left: &TaskBoardItem, right: &TaskBoardItem) -> Ordering {
    right
        .priority
        .cmp(&left.priority)
        .then_with(|| left.created_at.cmp(&right.created_at))
        .then_with(|| left.id.cmp(&right.id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::{TaskBoardItem, TaskBoardPriority};

    fn item(id: &str) -> TaskBoardItem {
        TaskBoardItem::new(
            id.to_string(),
            id.to_string(),
            String::new(),
            format!("2026-07-22T00:00:0{id}Z"),
        )
    }

    #[test]
    fn defaults_keep_legacy_priority_order() {
        let mut low = item("1");
        low.priority = TaskBoardPriority::Low;
        let mut high = item("2");
        high.priority = TaskBoardPriority::High;
        let mut items = vec![low, high];

        sort_task_board_items(&mut items);

        assert_eq!(items[0].id, "2");
        assert_eq!(items[1].id, "1");
    }

    #[test]
    fn anchors_fill_remaining_slots_with_defaults() {
        let mut anchor = item("anchor");
        anchor.lane_position = Some(1);
        anchor.lane_origin = Some(TaskBoardLaneOrigin::Manual {
            actor: "person".into(),
        });
        anchor.lane_set_at = Some("2026-07-22T00:00:00Z".into());
        let mut highest = item("highest");
        highest.priority = TaskBoardPriority::Critical;
        let mut items = vec![anchor, item("normal"), highest];

        sort_task_board_items(&mut items);

        assert_eq!(
            items.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(),
            ["highest", "anchor", "normal"]
        );
    }

    #[test]
    fn placement_requires_one_complete_provenance_tuple() {
        let mut item = item("incomplete");
        item.lane_position = Some(0);
        assert_eq!(
            validate_lane_placement(&item),
            Err("lane position, origin, and set_at must be present together")
        );
    }

    #[test]
    fn lane_order_rejects_duplicate_and_out_of_range_anchors() {
        let mut duplicate_a = item("duplicate-a");
        let mut duplicate_b = item("duplicate-b");
        for item in [&mut duplicate_a, &mut duplicate_b] {
            item.lane_position = Some(0);
            item.lane_origin = Some(TaskBoardLaneOrigin::Manual {
                actor: "person".into(),
            });
            item.lane_set_at = Some("2026-07-22T10:00:00Z".into());
        }
        assert_eq!(
            validate_task_board_lane_order(&[duplicate_a, duplicate_b]),
            Err("lane positions must be unique within a live lane")
        );
    }
}
