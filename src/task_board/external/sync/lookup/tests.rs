use super::*;
use crate::task_board::types::{ExternalRef, ExternalRefSyncState, TaskBoardStatus};

fn item_with_ref(id: &str, execution_repository: Option<&str>, external_id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    );
    item.execution_repository = execution_repository.map(str::to_string);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: external_id.into(),
        url: None,
        sync_state: None,
    }];
    item
}

#[test]
fn resolve_parent_item_id_matches_a_legacy_cross_repo_parent_by_its_own_repo() {
    let parent = item_with_ref("legacy-parent", Some("other-owner/other-repo"), "42");
    let index = ProviderItemIndex::build(vec![TaskBoardSyncItemSnapshot::new(parent, 1)]);
    let task = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "child-owner/child-repo#7"),
        title: "Child issue".into(),
        status: TaskBoardStatus::Backlog,
        project_id: Some("child-owner/child-repo".into()),
        parent_reference: Some(ExternalTaskRef::new(
            ExternalProvider::GitHub,
            "other-owner/other-repo#42",
        )),
        ..ExternalTask::default()
    };

    let resolved = resolve_parent_item_id(&index, &task);

    assert_eq!(resolved, Some("legacy-parent".to_string()));
}

#[test]
fn legacy_alias_uses_the_first_project_candidate_only() {
    let mut item = TaskBoardItem::new(
        "legacy-item".into(),
        "Legacy issue".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    );
    item.project_id = Some("fallback-owner/fallback-repo".into());
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: Some(ExternalRefSyncState {
            project_id: Some("primary-owner/primary-repo".into()),
            ..ExternalRefSyncState::default()
        }),
    }];
    let index = ProviderItemIndex::build(vec![TaskBoardSyncItemSnapshot::new(item, 7)]);

    let primary = ExternalTaskRef::new(ExternalProvider::GitHub, "primary-owner/primary-repo#42");
    assert!(
        index
            .active_snapshot(&primary, Some("primary-owner/primary-repo"))
            .expect("lookup succeeds")
            .is_some(),
        "the first-present sync-state project must resolve the alias"
    );

    let fallback =
        ExternalTaskRef::new(ExternalProvider::GitHub, "fallback-owner/fallback-repo#42");
    assert!(
        index
            .active_snapshot(&fallback, Some("fallback-owner/fallback-repo"))
            .expect("lookup succeeds")
            .is_none(),
        "item project must not be indexed once a higher-precedence project is present"
    );
}

#[test]
fn qualified_project_resolves_before_an_ambiguous_bare_legacy_id() {
    let item_a = item_with_ref("item-a", Some("owner-a/repo-a"), "42");
    let item_b = item_with_ref("item-b", Some("owner-b/repo-b"), "42");
    let index = ProviderItemIndex::build(vec![
        TaskBoardSyncItemSnapshot::new(item_a, 1),
        TaskBoardSyncItemSnapshot::new(item_b, 2),
    ]);

    let bare = ExternalTaskRef::new(ExternalProvider::GitHub, "42");
    let resolved_a = index
        .active_snapshot(&bare, Some("owner-a/repo-a"))
        .expect("project-qualified lookup succeeds")
        .expect("resolves to item-a");
    assert_eq!(resolved_a.item.id, "item-a");

    let resolved_b = index
        .active_snapshot(&bare, Some("owner-b/repo-b"))
        .expect("project-qualified lookup succeeds")
        .expect("resolves to item-b");
    assert_eq!(resolved_b.item.id, "item-b");
}

#[test]
fn qualified_github_refs_match_repository_names_case_insensitively() {
    let item = item_with_ref("item-1", None, "Owner/Repo#42");
    let index = ProviderItemIndex::build(vec![TaskBoardSyncItemSnapshot::new(item, 1)]);
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#42");

    let resolved = index
        .active_snapshot(&reference, Some("owner/repo"))
        .expect("qualified lookup succeeds")
        .expect("qualified ref resolves");

    assert_eq!(resolved.item.id, "item-1");
}

#[test]
fn a_bare_ambiguous_legacy_id_fails_closed_without_mutation() {
    let item_a = item_with_ref("item-a", Some("owner-a/repo-a"), "42");
    let item_b = item_with_ref("item-b", Some("owner-b/repo-b"), "42");
    let index = ProviderItemIndex::build(vec![
        TaskBoardSyncItemSnapshot::new(item_a, 1),
        TaskBoardSyncItemSnapshot::new(item_b, 2),
    ]);

    let bare = ExternalTaskRef::new(ExternalProvider::GitHub, "42");
    let error = index
        .active_snapshot(&bare, None)
        .expect_err("an ambiguous bare id must fail closed");
    assert_eq!(error.code(), "WORKFLOW_IO");
}

#[test]
fn an_active_and_excluded_collision_is_ambiguous_for_both_classes() {
    let active = item_with_ref("active", Some("owner/repo"), "42");
    let mut excluded = item_with_ref("excluded", Some("owner/repo"), "42");
    excluded.deleted_at = Some("2026-07-15T11:00:00Z".into());
    excluded.tombstone_cause = Some(TaskBoardTombstoneCause::ProviderExclusion);
    let index = ProviderItemIndex::build(vec![
        TaskBoardSyncItemSnapshot::new(active, 1),
        TaskBoardSyncItemSnapshot::new(excluded, 2),
    ]);
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "42");

    assert!(
        index
            .active_snapshot(&reference, Some("owner/repo"))
            .is_err()
    );
    assert!(
        index
            .excluded_snapshot(&reference, Some("owner/repo"))
            .is_err()
    );
}

#[test]
fn a_qualified_tombstone_cannot_mask_a_different_exact_bare_item() {
    let active = item_with_ref("active", None, "42");
    let mut excluded = item_with_ref("excluded", Some("owner/repo"), "owner/repo#42");
    excluded.deleted_at = Some("2026-07-15T11:00:00Z".into());
    excluded.tombstone_cause = Some(TaskBoardTombstoneCause::ProviderExclusion);
    let index = ProviderItemIndex::build(vec![
        TaskBoardSyncItemSnapshot::new(active, 1),
        TaskBoardSyncItemSnapshot::new(excluded, 2),
    ]);
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "42");

    assert!(
        index
            .active_snapshot(&reference, Some("owner/repo"))
            .is_err()
    );
    assert!(
        index
            .excluded_snapshot(&reference, Some("owner/repo"))
            .is_err()
    );
}

#[test]
fn a_multi_ref_item_is_stored_once_regardless_of_how_many_keys_it_registers() {
    let mut item = item_with_ref("item-1", Some("owner/repo"), "1");
    item.external_refs.push(ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "2".into(),
        url: None,
        sync_state: None,
    });
    item.external_refs.push(ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "3".into(),
        url: None,
        sync_state: None,
    });
    let index = ProviderItemIndex::build(vec![TaskBoardSyncItemSnapshot::new(item, 1)]);

    assert_eq!(index.snapshots.len(), 1);
}

#[test]
fn a_bounded_large_batch_resolves_a_qualified_alias_without_scanning() {
    let mut snapshots = Vec::new();
    for offset in 0..2_000 {
        let item = item_with_ref(
            &format!("item-{offset}"),
            Some(&format!("owner/repo-{offset}")),
            "42",
        );
        snapshots.push(TaskBoardSyncItemSnapshot::new(item, i64::from(offset)));
    }
    let last_offset = 1_999;
    let index = ProviderItemIndex::build(snapshots);
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "42");
    let project = format!("owner/repo-{last_offset}");

    let resolved = index
        .active_snapshot(&reference, Some(&project))
        .expect("lookup succeeds")
        .expect("resolves the last qualified alias");

    assert_eq!(index.snapshots.len(), 2_000);
    assert_eq!(resolved.item.id, format!("item-{last_offset}"));
}
