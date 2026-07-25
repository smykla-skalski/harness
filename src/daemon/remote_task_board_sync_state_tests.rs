use std::collections::HashMap;

use super::{TaskBoardReadListResponse, project_task_board_list};
use crate::daemon::protocol::TaskBoardListItemsRequest;
use crate::daemon::service::TaskBoardListSource;
use crate::task_board::{
    ExternalRef, ExternalRefProvider, ExternalRefSyncState, TaskBoardItem, TaskBoardStatus,
};

const CACHED_PROVIDER_BODY: &str = "a very long cached issue body that no client decodes";

fn item_with_synced_ref() -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "item-1".into(),
        "Title".into(),
        "item body".into(),
        "2026-07-25T00:00:00Z".into(),
    );
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "owner/repo#1".to_owned(),
        url: Some("https://github.com/owner/repo/issues/1".to_owned()),
        sync_state: Some(ExternalRefSyncState {
            title: Some("cached provider title".to_owned()),
            body: Some(CACHED_PROVIDER_BODY.to_owned()),
            status: Some(TaskBoardStatus::InProgress),
            project_id: Some("project-1".to_owned()),
            updated_at: Some("2026-07-25T00:00:00Z".to_owned()),
            synced_at: Some("2026-07-25T00:00:01Z".to_owned()),
            labels: vec!["bug".to_owned()],
        }),
    }];
    item
}

fn list_source() -> TaskBoardListSource {
    TaskBoardListSource {
        items: vec![item_with_synced_ref()],
        items_change_seq: 7,
        item_revisions: HashMap::new(),
        progress_rollups: HashMap::new(),
    }
}

fn projected(viewer: bool) -> TaskBoardReadListResponse {
    let selection = TaskBoardListItemsRequest::default()
        .validated_selection()
        .expect("an unfiltered read is valid");
    project_task_board_list(list_source(), &selection, viewer).expect("project list")
}

fn projected_sync_state(viewer: bool) -> Option<ExternalRefSyncState> {
    match projected(viewer) {
        TaskBoardReadListResponse::Full(response) => response.items[0].external_refs[0]
            .sync_state
            .clone(),
        TaskBoardReadListResponse::Viewer(_) => None,
    }
}

#[test]
fn the_list_drops_the_cached_provider_text() {
    let state = projected_sync_state(false).expect("the ref keeps its sync state");

    assert_eq!(state.body, None, "the cached provider body is the payload");
    assert_eq!(state.title, None, "the cached provider title goes with it");
}

#[test]
fn the_list_keeps_what_the_client_reads() {
    let state = projected_sync_state(false).expect("the ref keeps its sync state");

    assert_eq!(
        state.status,
        Some(TaskBoardStatus::InProgress),
        "status drives the card glyph and is the only field the client decodes"
    );
    assert_eq!(state.labels, vec!["bug".to_owned()]);
    assert_eq!(state.synced_at.as_deref(), Some("2026-07-25T00:00:01Z"));
}

#[test]
fn the_ref_itself_survives_the_trim() {
    let TaskBoardReadListResponse::Full(response) = projected(false) else {
        panic!("a non-viewer read returns the full response");
    };
    let reference = &response.items[0].external_refs[0];

    assert_eq!(reference.provider, ExternalRefProvider::GitHub);
    assert_eq!(reference.external_id, "owner/repo#1");
    assert!(
        reference.url.is_some(),
        "the link is what the card opens, and it is cheap"
    );
}

/// The remote viewer projection already drops external refs wholesale, so the
/// trim must not be what that path depends on.
#[test]
fn the_viewer_projection_is_untouched() {
    let response = projected(true);

    assert!(
        matches!(response, TaskBoardReadListResponse::Viewer(_)),
        "a viewer read still gets the viewer projection"
    );
}
