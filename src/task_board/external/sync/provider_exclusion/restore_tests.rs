use super::*;

#[tokio::test]
async fn restore_resolves_by_the_stored_snapshot_via_the_index() {
    let store = FakeStore::default();
    let mut stored = item("stored-legacy-id");
    stored.deleted_at = Some("2026-07-22T00:00:00Z".into());
    stored.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    stored.tags = vec!["local-only".into(), "duplicate".into()];
    stored.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: Some(crate::task_board::types::ExternalRefSyncState {
            labels: vec!["duplicate".into()],
            ..Default::default()
        }),
    }];
    let expected = TaskBoardSyncItemSnapshot::new(stored, 7);
    let index = ProviderItemIndex::build(vec![expected]);
    *store.restore_result.lock().expect("lock") = Some(ProviderExclusionRestoreOutcome::Restored(
        Box::new(item("stored-legacy-id")),
    ));

    let mut task = task("42");
    task.labels = vec!["kind/feature".into()];
    let mut operations = Vec::new();

    let handled = try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        pull_options(false),
        ExternalProvider::GitHub,
        &task,
        Some("parent-1".into()),
        &mut operations,
    )
    .await
    .expect("restore call succeeds");

    assert!(handled);
    assert_eq!(operations.len(), 1);
    assert!(operations[0].applied);
    let (seen_expected, _patch, _conflicts) = store
        .restore_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("restore was attempted");
    assert_eq!(seen_expected.item.id, "stored-legacy-id");
    assert_eq!(seen_expected.item_revision, 7);
}

#[tokio::test]
async fn restore_finds_nothing_when_no_excluded_snapshot_matches() {
    let store = FakeStore::default();
    let index = ProviderItemIndex::build(Vec::new());
    let task = task("999");
    let mut operations = Vec::new();

    let handled = try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        pull_options(false),
        ExternalProvider::GitHub,
        &task,
        None,
        &mut operations,
    )
    .await
    .expect("restore call succeeds");

    assert!(!handled);
    assert!(operations.is_empty());
    assert!(store.restore_seen.lock().expect("lock").is_none());
}

#[tokio::test]
async fn restore_dry_run_reports_the_actual_stored_id_without_mutating() {
    let store = FakeStore::default();
    let mut stored = item("stored-legacy-id");
    stored.deleted_at = Some("2026-07-22T00:00:00Z".into());
    stored.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    stored.tags = vec!["duplicate".into()];
    stored.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    let expected = TaskBoardSyncItemSnapshot::new(stored, 7);
    let index = ProviderItemIndex::build(vec![expected]);
    let task = task("42");
    let mut operations = Vec::new();

    let handled = try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        pull_options(true),
        ExternalProvider::GitHub,
        &task,
        None,
        &mut operations,
    )
    .await
    .expect("dry-run restore succeeds");

    assert!(handled);
    assert_eq!(operations.len(), 1);
    assert!(operations[0].dry_run);
    assert!(!operations[0].applied);
    assert_eq!(
        operations[0].board_item_id.as_deref(),
        Some("stored-legacy-id")
    );
    assert!(
        store.restore_seen.lock().expect("lock").is_none(),
        "dry-run must never call the store"
    );
}

#[tokio::test]
async fn restore_fails_closed_when_the_stored_tags_lost_the_matched_label() {
    let store = FakeStore::default();
    let mut stored = item("stored-legacy-id");
    stored.deleted_at = Some("2026-07-22T00:00:00Z".into());
    stored.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    stored.tags = vec!["kind/bug".into()];
    stored.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    let expected = TaskBoardSyncItemSnapshot::new(stored, 7);
    let index = ProviderItemIndex::build(vec![expected]);
    let task = task("42");
    let mut operations = Vec::new();

    let error = try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        pull_options(false),
        ExternalProvider::GitHub,
        &task,
        None,
        &mut operations,
    )
    .await
    .expect_err("a tombstone missing its canonical exclusion label must fail closed");

    assert_eq!(error.code(), "WORKFLOW_IO");
    assert!(
        store.restore_seen.lock().expect("lock").is_none(),
        "a corrupt tombstone must never reach the store"
    );
}

#[tokio::test]
async fn restore_reports_handled_without_creating_when_the_transaction_finds_a_stale_cas() {
    let store = FakeStore::default();
    let mut stored = item("stored-legacy-id");
    stored.deleted_at = Some("2026-07-22T00:00:00Z".into());
    stored.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    stored.tags = vec!["duplicate".into()];
    stored.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    let expected = TaskBoardSyncItemSnapshot::new(stored, 7);
    let index = ProviderItemIndex::build(vec![expected]);
    *store.restore_result.lock().expect("lock") = Some(ProviderExclusionRestoreOutcome::NotApplied);
    let task = task("42");
    let mut operations = Vec::new();

    let handled = try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        pull_options(false),
        ExternalProvider::GitHub,
        &task,
        None,
        &mut operations,
    )
    .await
    .expect("restore call succeeds");

    assert!(
        handled,
        "the batch index already proved this ref belonged to an excluded item; a stale \
         transaction-level CAS must never fall through to create a duplicate"
    );
    assert!(
        operations.is_empty(),
        "a NotApplied transaction outcome reports nothing this round"
    );
}

#[tokio::test]
async fn restore_publishes_a_conflict_operation_when_the_store_reports_one() {
    let store = FakeStore::default();
    let mut stored = item("stored-legacy-id");
    stored.title = "Stored title".into();
    stored.deleted_at = Some("2026-07-22T00:00:00Z".into());
    stored.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    stored.tags = vec!["duplicate".into()];
    stored.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    let expected = TaskBoardSyncItemSnapshot::new(stored, 7);
    let index = ProviderItemIndex::build(vec![expected]);
    *store.restore_result.lock().expect("lock") =
        Some(ProviderExclusionRestoreOutcome::ConflictPublished);
    let mut task = task("42");
    task.title = "Provider title".into();
    let mut operations = Vec::new();

    let handled = try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        both_report_options(false),
        ExternalProvider::GitHub,
        &task,
        None,
        &mut operations,
    )
    .await
    .expect("restore call succeeds");

    assert!(handled);
    assert_eq!(operations.len(), 1);
    assert!(!operations[0].applied);
    assert!(matches!(operations[0].action, ExternalSyncAction::Conflict));

    let (_expected, _patch, conflicts) = store
        .restore_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("restore was attempted");
    let conflicts = conflicts.expect("Both+Report must pass Some conflicts");
    assert!(
        !conflicts.is_empty(),
        "disagreeing fields must be built into the conflicts list"
    );
}

#[tokio::test]
async fn restore_passes_some_empty_conflicts_to_supersede_stale_rows_when_fields_agree() {
    let store = FakeStore::default();
    let stored_item = item("stored-legacy-id");
    let mut stored = stored_item.clone();
    stored.deleted_at = Some("2026-07-22T00:00:00Z".into());
    stored.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    stored.tags = vec!["duplicate".into()];
    stored.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    let expected = TaskBoardSyncItemSnapshot::new(stored, 7);
    let index = ProviderItemIndex::build(vec![expected]);
    *store.restore_result.lock().expect("lock") = Some(ProviderExclusionRestoreOutcome::Restored(
        Box::new(stored_item),
    ));
    // Same title/body/status as `item("stored-legacy-id")`, so no field disagrees.
    let task = task("42");
    let mut operations = Vec::new();

    let handled = try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        both_report_options(false),
        ExternalProvider::GitHub,
        &task,
        None,
        &mut operations,
    )
    .await
    .expect("restore call succeeds");

    assert!(handled);
    let (_expected, _patch, conflicts) = store
        .restore_seen
        .lock()
        .expect("lock")
        .clone()
        .expect("restore was attempted");
    assert_eq!(
        conflicts,
        Some(Vec::new()),
        "Both+Report with nothing disagreeing must still pass Some(empty) so the DB layer \
         supersedes any stale open rows"
    );
}

#[tokio::test]
async fn restore_reports_only_fields_the_pull_applied() {
    let store = FakeStore::default();
    let mut stored = item("stored-legacy-id");
    stored.title = "Local title".into();
    stored.body = "Local body".into();
    stored.project_id = Some("local/project".into());
    stored.deleted_at = Some("2026-07-22T00:00:00Z".into());
    stored.tombstone_cause = Some(crate::task_board::TaskBoardTombstoneCause::ProviderExclusion);
    stored.tags = vec!["duplicate".into()];
    stored.external_refs = vec![crate::task_board::types::ExternalRef {
        provider: ExternalRefProvider::Todoist,
        external_id: "42".into(),
        url: None,
        sync_state: Some(crate::task_board::types::ExternalRefSyncState {
            title: Some("Local title".into()),
            body: Some("Local body".into()),
            project_id: Some("local/project".into()),
            labels: vec!["duplicate".into()],
            ..Default::default()
        }),
    }];
    let expected = TaskBoardSyncItemSnapshot::new(stored, 7);
    let index = ProviderItemIndex::build(vec![expected]);
    *store.restore_result.lock().expect("lock") = Some(ProviderExclusionRestoreOutcome::Restored(
        Box::new(item("stored-legacy-id")),
    ));
    let mut incoming = task("42");
    incoming.reference = ExternalTaskRef::new(ExternalProvider::Todoist, "42");
    incoming.title = "Provider title".into();
    incoming.body = "Provider body".into();
    incoming.project_id = Some("provider/project".into());
    incoming.labels = vec!["kind/bug".into()];
    let mut operations = Vec::new();

    try_restore_provider_exclusion_tombstone(
        &store,
        &index,
        todoist_pull_options(false),
        ExternalProvider::Todoist,
        &incoming,
        None,
        &mut operations,
    )
    .await
    .expect("restore succeeds");

    assert_eq!(operations.len(), 1);
    assert_eq!(
        operations[0].changed_fields,
        vec![
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Status,
            ExternalSyncField::Project,
        ]
    );
}
