use std::collections::{HashMap, VecDeque};

use serde::{Deserialize, Serialize};

use super::types::{TaskBoardItem, TaskBoardItemKind, TaskBoardStatus};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardProgressRollup {
    pub total: usize,
    pub done: usize,
    pub remaining: usize,
    pub blocked: usize,
    pub waiting_on_human: usize,
    pub is_empty: bool,
}

/// Compute a per-umbrella progress roll-up over each umbrella's full
/// descendant subtree. Derived fresh from `items` on every call rather than
/// persisted, so it is never stale and needs no schema. Only live
/// umbrella-kind items get an entry.
///
/// Aggregates leaves-up in one pass: each item's subtree total folds into its
/// parent exactly once, so the cost is linear in the live item count instead
/// of quadratic from walking every umbrella's subtree independently (which a
/// chain of nested umbrellas would otherwise make expensive).
#[must_use]
pub fn build_progress_rollups(items: &[TaskBoardItem]) -> HashMap<String, TaskBoardProgressRollup> {
    let live_by_id: HashMap<&str, &TaskBoardItem> = items
        .iter()
        .filter(|item| !item.is_deleted())
        .map(|item| (item.id.as_str(), item))
        .collect();

    let mut children_by_parent: HashMap<&str, Vec<&str>> = HashMap::new();
    for item in live_by_id.values() {
        if let Some(parent_id) = item.parent_item_id.as_deref()
            && live_by_id.contains_key(parent_id)
        {
            children_by_parent
                .entry(parent_id)
                .or_default()
                .push(item.id.as_str());
        }
    }

    let mut pending_children: HashMap<&str, usize> = live_by_id
        .keys()
        .map(|&id| (id, children_by_parent.get(id).map_or(0, Vec::len)))
        .collect();
    let mut subtree_totals: HashMap<&str, TaskBoardProgressRollup> = HashMap::new();
    let mut ready: VecDeque<&str> = pending_children
        .iter()
        .filter(|&(_, &count)| count == 0)
        .map(|(&id, _)| id)
        .collect();

    // Leaves-first: an item becomes ready only once every live child of its
    // own has folded its subtree total in. #313 rejects real cycles at write
    // time; a corrupted one here just leaves its members with
    // `pending_children > 0` forever, so they're silently skipped rather
    // than looped over.
    while let Some(id) = ready.pop_front() {
        let Some(item) = live_by_id.get(id).copied() else {
            continue;
        };
        let Some(parent_id) = item
            .parent_item_id
            .as_deref()
            .filter(|parent| live_by_id.contains_key(*parent))
        else {
            continue;
        };
        let own_total = subtree_totals.get(id).copied().unwrap_or_default();
        let parent_total = subtree_totals.entry(parent_id).or_default();
        parent_total.total += 1 + own_total.total;
        parent_total.done += own_total.done;
        parent_total.remaining += own_total.remaining;
        parent_total.blocked += own_total.blocked;
        parent_total.waiting_on_human += own_total.waiting_on_human;
        count_by_status(parent_total, item.status);

        if let Some(remaining) = pending_children.get_mut(parent_id) {
            *remaining -= 1;
            if *remaining == 0 {
                ready.push_back(parent_id);
            }
        }
    }

    live_by_id
        .values()
        .filter(|item| item.kind == TaskBoardItemKind::Umbrella)
        .map(|umbrella| {
            let mut rollup = subtree_totals
                .get(umbrella.id.as_str())
                .copied()
                .unwrap_or_default();
            rollup.is_empty = rollup.total == 0;
            (umbrella.id.clone(), rollup)
        })
        .collect()
}

fn count_by_status(rollup: &mut TaskBoardProgressRollup, status: TaskBoardStatus) {
    match status.canonical_persisted_status() {
        TaskBoardStatus::Done => rollup.done += 1,
        TaskBoardStatus::Failed => rollup.blocked += 1,
        TaskBoardStatus::HumanRequired => rollup.waiting_on_human += 1,
        _ => rollup.remaining += 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::types::TaskBoardStatus;

    fn item(
        id: &str,
        kind: TaskBoardItemKind,
        status: TaskBoardStatus,
        parent: Option<&str>,
    ) -> TaskBoardItem {
        let mut item = TaskBoardItem::new(
            id.into(),
            "title".into(),
            String::new(),
            "2026-07-21T00:00:00Z".into(),
        );
        item.kind = kind;
        item.status = status;
        item.parent_item_id = parent.map(str::to_owned);
        item
    }

    #[test]
    fn umbrella_with_no_children_reports_empty_not_complete() {
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );

        let rollups = build_progress_rollups(&[umbrella]);
        let rollup = rollups["umbrella-1"];

        assert_eq!(rollup.total, 0);
        assert!(rollup.is_empty);
        assert_eq!(rollup.done, 0);
    }

    #[test]
    fn an_umbrella_with_all_children_done_is_not_reported_as_empty() {
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );
        let child = item(
            "child-1",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Done,
            Some("umbrella-1"),
        );

        let rollups = build_progress_rollups(&[umbrella, child]);
        let rollup = rollups["umbrella-1"];

        assert!(!rollup.is_empty);
        assert_eq!(rollup.total, 1);
        assert_eq!(rollup.done, 1);
    }

    #[test]
    fn only_umbrella_kind_items_get_a_rollup_entry() {
        let task = item(
            "task-1",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Done,
            None,
        );

        let rollups = build_progress_rollups(&[task]);

        assert!(rollups.is_empty());
    }

    #[test]
    fn deleted_umbrella_gets_no_rollup_entry() {
        let mut umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );
        umbrella.deleted_at = Some("2026-07-21T01:00:00Z".into());

        let rollups = build_progress_rollups(&[umbrella]);

        assert!(rollups.is_empty());
    }

    #[test]
    fn rollup_counts_direct_children_by_status_bucket() {
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );
        let done = item(
            "child-done",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Done,
            Some("umbrella-1"),
        );
        let in_progress = item(
            "child-in-progress",
            TaskBoardItemKind::Task,
            TaskBoardStatus::InProgress,
            Some("umbrella-1"),
        );
        let failed = item(
            "child-failed",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Failed,
            Some("umbrella-1"),
        );
        let human_required = item(
            "child-human-required",
            TaskBoardItemKind::Task,
            TaskBoardStatus::HumanRequired,
            Some("umbrella-1"),
        );

        let rollups =
            build_progress_rollups(&[umbrella, done, in_progress, failed, human_required]);
        let rollup = rollups["umbrella-1"];

        assert_eq!(rollup.total, 4);
        assert_eq!(rollup.done, 1);
        assert_eq!(rollup.remaining, 1);
        assert_eq!(rollup.blocked, 1);
        assert_eq!(rollup.waiting_on_human, 1);
        assert!(!rollup.is_empty);
    }

    #[test]
    fn legacy_status_aliases_map_to_the_same_bucket_as_their_canonical_status() {
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );
        let legacy_blocked = item(
            "child-blocked",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Blocked,
            Some("umbrella-1"),
        );
        let legacy_needs_you = item(
            "child-needs-you",
            TaskBoardItemKind::Task,
            TaskBoardStatus::NeedsYou,
            Some("umbrella-1"),
        );

        let rollups = build_progress_rollups(&[umbrella, legacy_blocked, legacy_needs_you]);
        let rollup = rollups["umbrella-1"];

        assert_eq!(rollup.blocked, 1);
        assert_eq!(rollup.waiting_on_human, 1);
    }

    #[test]
    fn rollup_covers_the_full_subtree_deduping_each_descendant_once() {
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );
        let child_umbrella = item(
            "umbrella-2",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            Some("umbrella-1"),
        );
        let grandchild = item(
            "task-1",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Done,
            Some("umbrella-2"),
        );

        let rollups = build_progress_rollups(&[umbrella, child_umbrella, grandchild]);

        let root_rollup = rollups["umbrella-1"];
        assert_eq!(root_rollup.total, 2);
        assert_eq!(root_rollup.done, 1);
        assert_eq!(root_rollup.remaining, 1);

        let nested_rollup = rollups["umbrella-2"];
        assert_eq!(nested_rollup.total, 1);
        assert_eq!(nested_rollup.done, 1);
    }

    #[test]
    fn deleted_descendants_are_excluded_from_the_rollup() {
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );
        let live_child = item(
            "child-live",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Todo,
            Some("umbrella-1"),
        );
        let mut deleted_child = item(
            "child-deleted",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Todo,
            Some("umbrella-1"),
        );
        deleted_child.deleted_at = Some("2026-07-21T01:00:00Z".into());

        let rollups = build_progress_rollups(&[umbrella, live_child, deleted_child]);
        let rollup = rollups["umbrella-1"];

        assert_eq!(rollup.total, 1);
    }

    #[test]
    fn a_mutual_parent_cycle_terminates_safely_instead_of_looping() {
        // #313 rejects this at write time; the read-time aggregation must
        // still terminate if the stored graph is ever corrupted. Neither
        // side of a mutual cycle ever has all its children resolved, so
        // both are silently skipped rather than counted.
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            Some("child-1"),
        );
        let child = item(
            "child-1",
            TaskBoardItemKind::Task,
            TaskBoardStatus::Done,
            Some("umbrella-1"),
        );

        let rollups = build_progress_rollups(&[umbrella, child]);
        let rollup = rollups["umbrella-1"];

        assert_eq!(rollup.total, 0);
        assert!(rollup.is_empty);
    }

    #[test]
    fn progress_reflects_child_status_changes_without_editing_the_umbrella() {
        let umbrella = item(
            "umbrella-1",
            TaskBoardItemKind::Umbrella,
            TaskBoardStatus::Todo,
            None,
        );
        let mut child = item(
            "child-1",
            TaskBoardItemKind::Task,
            TaskBoardStatus::InProgress,
            Some("umbrella-1"),
        );

        let before = build_progress_rollups(&[umbrella.clone(), child.clone()])["umbrella-1"];
        assert_eq!(before.remaining, 1);
        assert_eq!(before.done, 0);

        child.status = TaskBoardStatus::Done;
        let after = build_progress_rollups(&[umbrella, child])["umbrella-1"];
        assert_eq!(after.remaining, 0);
        assert_eq!(after.done, 1);
    }
}
