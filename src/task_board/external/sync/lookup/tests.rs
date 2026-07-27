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
        status: TaskBoardStatus::Inbox,
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
            .found()
            .is_some(),
        "the first-present sync-state project must resolve the alias"
    );

    let fallback =
        ExternalTaskRef::new(ExternalProvider::GitHub, "fallback-owner/fallback-repo#42");
    assert!(
        index
            .active_snapshot(&fallback, Some("fallback-owner/fallback-repo"))
            .found()
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
        .found()
        .expect("resolves to item-a");
    assert_eq!(resolved_a.item.id, "item-a");

    let resolved_b = index
        .active_snapshot(&bare, Some("owner-b/repo-b"))
        .found()
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
        .found()
        .expect("qualified ref resolves");

    assert_eq!(resolved.item.id, "item-1");
}

#[test]
fn a_bare_ambiguous_legacy_id_reports_ambiguous_without_mutation() {
    let item_a = item_with_ref("item-a", Some("owner-a/repo-a"), "42");
    let item_b = item_with_ref("item-b", Some("owner-b/repo-b"), "42");
    let index = ProviderItemIndex::build(vec![
        TaskBoardSyncItemSnapshot::new(item_a, 1),
        TaskBoardSyncItemSnapshot::new(item_b, 2),
    ]);

    let bare = ExternalTaskRef::new(ExternalProvider::GitHub, "42");

    // Still resolves to nothing, so no item is touched; the caller now decides
    // what to do about it rather than the whole scope unwinding.
    assert!(matches!(
        index.active_snapshot(&bare, None),
        SnapshotMatch::Ambiguous
    ));
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

    assert!(matches!(
        index.active_snapshot(&reference, Some("owner/repo")),
        SnapshotMatch::Ambiguous
    ));
    assert!(matches!(
        index.excluded_snapshot(&reference, Some("owner/repo")),
        SnapshotMatch::Ambiguous
    ));
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

    assert!(matches!(
        index.active_snapshot(&reference, Some("owner/repo")),
        SnapshotMatch::Ambiguous
    ));
    assert!(matches!(
        index.excluded_snapshot(&reference, Some("owner/repo")),
        SnapshotMatch::Ambiguous
    ));
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
        .found()
        .expect("resolves the last qualified alias");

    assert_eq!(index.snapshots.len(), 2_000);
    assert_eq!(resolved.item.id, format!("item-{last_offset}"));
}

/// The shape a case-varying import left behind: one board item claiming
/// `owner/repo#689` and another claiming `Owner/repo#689`, which canonicalise
/// to the same key.
fn duplicate_case_index() -> ProviderItemIndex {
    ProviderItemIndex::build(vec![
        TaskBoardSyncItemSnapshot::new(item_with_ref("legacy", None, "owner/repo#689"), 1),
        TaskBoardSyncItemSnapshot::new(item_with_ref("current", None, "Owner/repo#689"), 2),
    ])
}

#[test]
fn a_reference_two_items_claim_reports_ambiguous_rather_than_failing() {
    let index = duplicate_case_index();
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "Owner/repo#689");

    let matched = index.active_snapshot(&reference, Some("owner/repo"));

    assert!(
        matches!(matched, SnapshotMatch::Ambiguous),
        "a duplicated claim is reported to the caller, not raised as a sync failure"
    );
}

#[test]
fn an_unambiguous_reference_still_resolves_beside_a_duplicated_one() {
    let mut snapshots = vec![
        TaskBoardSyncItemSnapshot::new(item_with_ref("legacy", None, "owner/repo#689"), 1),
        TaskBoardSyncItemSnapshot::new(item_with_ref("current", None, "Owner/repo#689"), 2),
    ];
    snapshots.push(TaskBoardSyncItemSnapshot::new(
        item_with_ref("healthy", None, "owner/repo#700"),
        3,
    ));
    let index = ProviderItemIndex::build(snapshots);
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#700");

    let matched = index.active_snapshot(&reference, Some("owner/repo"));

    let SnapshotMatch::Found(snapshot) = matched else {
        panic!("the healthy reference still resolves");
    };
    assert_eq!(snapshot.item.id, "healthy");
}

#[test]
fn a_reference_no_item_claims_is_missing_not_ambiguous() {
    let index = duplicate_case_index();
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "owner/repo#999");

    let matched = index.active_snapshot(&reference, Some("owner/repo"));

    assert!(matches!(matched, SnapshotMatch::Missing));
}
