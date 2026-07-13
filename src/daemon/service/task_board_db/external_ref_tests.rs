use super::*;
use crate::task_board::{ExternalRefProvider, ExternalRefSyncState};

#[test]
fn external_ref_replacement_preserves_matching_daemon_sync_state() {
    let baseline = complete_sync_state("Remote review");
    let mut item = task_board_item();
    item.external_refs = vec![
        external_ref(
            "issue-12",
            "https://github.com/example/project/issues/12",
            None,
        ),
        external_ref(
            "review-42",
            "https://github.com/example/project/pull/42",
            Some(baseline.clone()),
        ),
    ];
    let request = TaskBoardUpdateItemRequest {
        external_refs: Some(vec![
            external_ref(
                "issue-13",
                "https://github.com/example/project/issues/13",
                None,
            ),
            external_ref(
                "review-42",
                "https://github.com/example/project/pull/42?view=files",
                None,
            ),
        ]),
        ..TaskBoardUpdateItemRequest::default()
    };

    apply_update_request(&mut item, &request);

    assert_eq!(item.external_refs.len(), 2);
    assert_eq!(item.external_refs[0].sync_state, None);
    assert_eq!(item.external_refs[1].sync_state, Some(baseline));
    assert_eq!(
        item.external_refs[1].url.as_deref(),
        Some("https://github.com/example/project/pull/42?view=files")
    );
}

#[test]
fn external_ref_replacement_rejects_stale_explicit_sync_state() {
    let current = complete_sync_state("Current baseline");
    let stale = complete_sync_state("Stale client baseline");
    let mut item = task_board_item();
    item.external_refs = vec![external_ref(
        "review-42",
        "https://github.com/example/project/pull/42",
        Some(current.clone()),
    )];
    let request = TaskBoardUpdateItemRequest {
        external_refs: Some(vec![external_ref(
            "review-42",
            "https://github.com/example/project/pull/42",
            Some(stale),
        )]),
        ..TaskBoardUpdateItemRequest::default()
    };

    apply_update_request(&mut item, &request);

    assert_eq!(item.external_refs[0].sync_state, Some(current));
}

#[test]
fn empty_external_ref_replacement_clears_every_reference() {
    let mut item = task_board_item();
    item.external_refs = vec![external_ref(
        "review-42",
        "https://github.com/example/project/pull/42",
        Some(complete_sync_state("Remote review")),
    )];
    let request = TaskBoardUpdateItemRequest {
        external_refs: Some(Vec::new()),
        ..TaskBoardUpdateItemRequest::default()
    };

    apply_update_request(&mut item, &request);

    assert!(item.external_refs.is_empty());
}

fn task_board_item() -> TaskBoardItem {
    TaskBoardItem::new(
        "task-ref-update".into(),
        "Task".into(),
        "Body".into(),
        "2026-07-13T10:00:00Z".into(),
    )
}

fn external_ref(
    external_id: &str,
    url: &str,
    sync_state: Option<ExternalRefSyncState>,
) -> ExternalRef {
    ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: external_id.into(),
        url: Some(url.into()),
        sync_state,
    }
}

fn complete_sync_state(title: &str) -> ExternalRefSyncState {
    ExternalRefSyncState {
        title: Some(title.into()),
        body: Some("Remote body".into()),
        status: Some(TaskBoardStatus::Done),
        project_id: Some("example/project".into()),
        updated_at: Some("2026-07-13T09:59:00Z".into()),
        synced_at: Some("2026-07-13T10:00:00Z".into()),
    }
}
