use std::collections::{HashMap, HashSet, VecDeque};

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
#[must_use]
pub fn build_progress_rollups(items: &[TaskBoardItem]) -> HashMap<String, TaskBoardProgressRollup> {
    let mut children_by_parent: HashMap<&str, Vec<&TaskBoardItem>> = HashMap::new();
    for item in items.iter().filter(|item| !item.is_deleted()) {
        if let Some(parent_id) = item.parent_item_id.as_deref() {
            children_by_parent.entry(parent_id).or_default().push(item);
        }
    }

    items
        .iter()
        .filter(|item| !item.is_deleted() && item.kind == TaskBoardItemKind::Umbrella)
        .map(|umbrella| {
            (
                umbrella.id.clone(),
                subtree_rollup(&umbrella.id, &children_by_parent),
            )
        })
        .collect()
}

/// Breadth-first over `children_by_parent`, tracking visited ids so a
/// corrupted parent chain (a cycle back through the root, say) terminates
/// instead of looping; #313 rejects such cycles at write time, so this is
/// belt-and-suspenders for read-time safety, not the primary guard.
fn subtree_rollup(
    root_id: &str,
    children_by_parent: &HashMap<&str, Vec<&TaskBoardItem>>,
) -> TaskBoardProgressRollup {
    let mut rollup = TaskBoardProgressRollup::default();
    let mut visited = HashSet::from([root_id]);
    let mut queue = VecDeque::from([root_id]);

    while let Some(parent_id) = queue.pop_front() {
        for child in children_by_parent.get(parent_id).into_iter().flatten() {
            if !visited.insert(child.id.as_str()) {
                continue;
            }
            rollup.total += 1;
            count_by_status(&mut rollup, child.status);
            queue.push_back(child.id.as_str());
        }
    }

    rollup.is_empty = rollup.total == 0;
    rollup
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

        let rollups = build_progress_rollups(&[umbrella, done, in_progress, failed, human_required]);
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
    fn a_corrupted_cycle_through_the_root_does_not_loop_or_count_the_root_as_its_own_descendant() {
        // #313 rejects this at write time; the read-time walk must still
        // terminate safely if the stored graph is ever corrupted.
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

        assert_eq!(rollup.total, 1);
        assert_eq!(rollup.done, 1);
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
