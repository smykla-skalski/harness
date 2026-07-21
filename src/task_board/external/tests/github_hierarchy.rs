use tempfile::tempdir;

use super::support::{
    FakeSyncClient, github_child_task, github_external_task, github_task_with_labels,
    github_umbrella_task,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::TaskBoardItemKind;
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConflictPolicy, ExternalSyncDirection,
    ExternalSyncOptions, ExternalTask, TaskBoardItem, TaskBoardStore, sync_external_tasks,
};

fn pull_options() -> ExternalSyncOptions {
    ExternalSyncOptions {
        provider: Some(ExternalProvider::GitHub),
        direction: ExternalSyncDirection::Pull,
        conflict_policy: ExternalSyncConflictPolicy::Report,
        dry_run: false,
        status: None,
    }
}

async fn sync(board: &TaskBoardStore, tasks: Vec<ExternalTask>) {
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(FakeSyncClient::new(
        ExternalProvider::GitHub,
        tasks,
    ))];
    sync_external_tasks(board, pull_options(), &clients)
        .await
        .expect("sync external tasks");
}

fn find_by_external_id(items: &[TaskBoardItem], external_id: &str) -> TaskBoardItem {
    items
        .iter()
        .find(|item| {
            item.external_refs
                .iter()
                .any(|reference| reference.external_id == external_id)
        })
        .cloned()
        .unwrap_or_else(|| panic!("no imported item for external id '{external_id}'"))
}

#[tokio::test]
async fn import_maps_github_labels_onto_board_tags() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    sync(
        &board,
        vec![github_task_with_labels(
            "owner/repo#50",
            "Labeled issue",
            "owner/repo",
            &["kind/enhancement", "area/board"],
        )],
    )
    .await;

    let item = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#50");
    assert_eq!(item.tags, vec!["kind/enhancement", "area/board"]);
}

#[tokio::test]
async fn resync_adds_new_labels_without_dropping_a_manually_added_tag() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    sync(
        &board,
        vec![github_task_with_labels(
            "owner/repo#51",
            "Labeled issue",
            "owner/repo",
            &["kind/enhancement"],
        )],
    )
    .await;
    let created = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#51");
    board
        .update(
            &created.id,
            TaskBoardItemPatch {
                tags: Some(vec!["kind/enhancement".into(), "manual-follow-up".into()]),
                ..Default::default()
            },
        )
        .expect("add a manual tag");

    sync(
        &board,
        vec![github_task_with_labels(
            "owner/repo#51",
            "Labeled issue",
            "owner/repo",
            &["kind/enhancement", "priority/high"],
        )],
    )
    .await;

    let item = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#51");
    assert!(item.tags.contains(&"manual-follow-up".to_string()));
    assert!(item.tags.contains(&"priority/high".to_string()));
    assert!(item.tags.contains(&"kind/enhancement".to_string()));
}

#[tokio::test]
async fn an_issue_that_tracks_children_imports_as_an_umbrella_without_manual_marking() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    sync(
        &board,
        vec![github_umbrella_task(
            "owner/repo#60",
            "Umbrella issue",
            "owner/repo",
        )],
    )
    .await;

    let item = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#60");
    assert_eq!(item.kind, TaskBoardItemKind::Umbrella);
}

#[tokio::test]
async fn a_plain_issue_imports_as_a_task() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    sync(
        &board,
        vec![github_external_task(
            "owner/repo#61",
            "Leaf issue",
            "owner/repo",
        )],
    )
    .await;

    let item = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#61");
    assert_eq!(item.kind, TaskBoardItemKind::Task);
}

#[tokio::test]
async fn importing_a_child_after_its_parent_carries_the_relationship_across() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    sync(
        &board,
        vec![github_umbrella_task(
            "owner/repo#70",
            "Umbrella issue",
            "owner/repo",
        )],
    )
    .await;
    let parent = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#70");

    sync(
        &board,
        vec![github_child_task(
            "owner/repo#71",
            "Child issue",
            "owner/repo",
            "owner/repo#70",
        )],
    )
    .await;

    let child = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#71");
    assert_eq!(child.parent_item_id, Some(parent.id));
}

#[tokio::test]
async fn a_child_whose_parent_is_not_yet_imported_still_imports_and_links_up_later() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    // The parent is not part of this sync at all: it may not be authored or
    // assigned to the importing viewer yet.
    sync(
        &board,
        vec![github_child_task(
            "owner/repo#81",
            "Child issue",
            "owner/repo",
            "owner/repo#80",
        )],
    )
    .await;
    let child = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#81");
    assert_eq!(child.parent_item_id, None);

    // The parent arrives on a later sync. Its own creation happens against a
    // board snapshot taken before this call started, so the child (already
    // on the board from the prior sync) still cannot resolve it this round.
    sync(
        &board,
        vec![
            github_umbrella_task("owner/repo#80", "Umbrella issue", "owner/repo"),
            github_child_task(
                "owner/repo#81",
                "Child issue",
                "owner/repo",
                "owner/repo#80",
            ),
        ],
    )
    .await;
    let child = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#81");
    assert_eq!(child.parent_item_id, None);

    // The next sync starts from a snapshot that already has the parent
    // persisted, so the deferred link resolves.
    sync(
        &board,
        vec![
            github_umbrella_task("owner/repo#80", "Umbrella issue", "owner/repo"),
            github_child_task(
                "owner/repo#81",
                "Child issue",
                "owner/repo",
                "owner/repo#80",
            ),
        ],
    )
    .await;
    let items = board.list(None).expect("list items");
    let parent = find_by_external_id(&items, "owner/repo#80");
    let child = find_by_external_id(&items, "owner/repo#81");
    assert_eq!(child.parent_item_id, Some(parent.id));
    assert_eq!(items.len(), 2, "linking must not duplicate either item");
}

#[tokio::test]
async fn resyncing_an_unchanged_hierarchy_is_a_no_op_not_a_duplicate() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let tasks = || {
        vec![
            github_umbrella_task("owner/repo#90", "Umbrella issue", "owner/repo"),
            github_child_task(
                "owner/repo#91",
                "Child issue",
                "owner/repo",
                "owner/repo#90",
            ),
        ]
    };

    sync(&board, tasks()).await;
    sync(&board, tasks()).await;
    sync(&board, tasks()).await;

    let items = board.list(None).expect("list items");
    assert_eq!(items.len(), 2);
    let parent = find_by_external_id(&items, "owner/repo#90");
    let child = find_by_external_id(&items, "owner/repo#91");
    assert_eq!(child.parent_item_id, Some(parent.id));
    assert_eq!(parent.kind, TaskBoardItemKind::Umbrella);
}

#[tokio::test]
async fn resync_reparents_a_child_when_its_tracking_issue_changes() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    // Both umbrellas land first so a later sync's board snapshot already has
    // them persisted when it tries to resolve the child's parent.
    sync(
        &board,
        vec![
            github_umbrella_task("owner/repo#100", "Old umbrella", "owner/repo"),
            github_umbrella_task("owner/repo#101", "New umbrella", "owner/repo"),
        ],
    )
    .await;
    sync(
        &board,
        vec![
            github_umbrella_task("owner/repo#100", "Old umbrella", "owner/repo"),
            github_umbrella_task("owner/repo#101", "New umbrella", "owner/repo"),
            github_child_task(
                "owner/repo#102",
                "Child issue",
                "owner/repo",
                "owner/repo#100",
            ),
        ],
    )
    .await;
    let items = board.list(None).expect("list items");
    let old_parent = find_by_external_id(&items, "owner/repo#100");
    let child = find_by_external_id(&items, "owner/repo#102");
    assert_eq!(child.parent_item_id, Some(old_parent.id));

    sync(
        &board,
        vec![
            github_umbrella_task("owner/repo#100", "Old umbrella", "owner/repo"),
            github_umbrella_task("owner/repo#101", "New umbrella", "owner/repo"),
            github_child_task(
                "owner/repo#102",
                "Child issue",
                "owner/repo",
                "owner/repo#101",
            ),
        ],
    )
    .await;

    let items = board.list(None).expect("list items");
    let new_parent = find_by_external_id(&items, "owner/repo#101");
    let child = find_by_external_id(&items, "owner/repo#102");
    assert_eq!(child.parent_item_id, Some(new_parent.id));
    assert_eq!(items.len(), 3);
}

#[tokio::test]
async fn the_umbrella_title_glyph_is_a_hint_when_the_body_has_no_checklist() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));

    sync(
        &board,
        vec![github_external_task(
            "owner/repo#110",
            "☂️ feat: umbrella by title alone",
            "owner/repo",
        )],
    )
    .await;

    let item = find_by_external_id(&board.list(None).expect("list items"), "owner/repo#110");
    assert_eq!(item.kind, TaskBoardItemKind::Umbrella);
}
