//! Paging assertions for the remote-viewer branch of the board list read.
//!
//! The viewer branch selects and pages a *different* item shape than the
//! operator branch - the redacted projection - and builds its own cursor and
//! `item_revisions` from it. Nothing else covers that branch, so a regression
//! confined to it would otherwise ship green.

use serde_json::{Value, json};

use crate::daemon::protocol::http_paths;
use crate::task_board::TaskBoardItem;

use super::remote_viewer_support::get_http_json;

/// Enough items that a small page size leaves several pages to walk.
const PAGED_ITEMS: usize = 7;
const PAGE_SIZE: usize = 3;
const PAGED_TAG: &str = "viewer-paged";

pub(super) async fn seed_paged_items(state: &crate::daemon::http::DaemonHttpState) {
    for index in 0..PAGED_ITEMS {
        let item: TaskBoardItem = serde_json::from_value(json!({
            "schema_version": 1,
            "id": format!("viewer-paged-{index:02}"),
            "title": format!("Viewer paged item {index:02}"),
            "body": "routine body",
            "status": "todo",
            "priority": "medium",
            "tags": [PAGED_TAG],
            "agent_mode": "headless",
            "created_at": "2026-07-13T00:02:00Z",
            "updated_at": format!("2026-07-13T00:02:{index:02}Z"),
        }))
        .expect("paged task item");
        state
            .async_db
            .get()
            .expect("async db")
            .create_task_board_item(item)
            .await
            .expect("seed paged task item");
    }
}

/// A viewer's pages have to cover its selection exactly once, and every page has
/// to carry the revisions for the items it actually returned - the projection
/// narrows `item_revisions` to the page, so a viewer that walked the board and
/// lost a revision could not pass the next position CAS.
pub(super) async fn assert_viewer_pages_cover_the_selection_once(
    client: &reqwest::Client,
    base_url: &str,
    viewer_id: &str,
) {
    let mut walked = Vec::new();
    let mut cursor: Option<String> = None;
    let mut pages = 0;
    loop {
        let page = get_http_json(client, base_url, &page_path(cursor.as_deref()), viewer_id).await;
        pages += 1;
        let ids = item_ids(&page);
        assert!(ids.len() <= PAGE_SIZE, "page {pages} broke the limit");
        assert_eq!(
            page["total_matched"],
            json!(PAGED_ITEMS),
            "a viewer's total counts its whole selection, not the page"
        );
        assert_revisions_match_the_page(&page, &ids, pages);
        walked.extend(ids);
        match page["next_cursor"].as_str() {
            Some(next) => cursor = Some(next.to_string()),
            None => break,
        }
        assert!(pages < PAGED_ITEMS, "viewer paging never terminated");
    }

    assert_eq!(pages, PAGED_ITEMS.div_ceil(PAGE_SIZE));
    let unpaged = item_ids(
        &get_http_json(
            client,
            base_url,
            &format!("{}?tag={PAGED_TAG}", http_paths::TASK_BOARD_ITEMS),
            viewer_id,
        )
        .await,
    );
    assert_eq!(walked.len(), PAGED_ITEMS, "a viewer's pages lost a row");
    assert_eq!(
        walked, unpaged,
        "paging changed a viewer's selection or its order"
    );
}

/// A viewer walking its own pages must never be handed a cursor that resumes
/// into text the projection withheld, so the facet used to page has to be one
/// the viewer can read back - and a viewer's page must still be projected.
pub(super) async fn assert_viewer_pages_stay_projected(
    client: &reqwest::Client,
    base_url: &str,
    viewer_id: &str,
) {
    let page = get_http_json(client, base_url, &page_path(None), viewer_id).await;
    let items = page["items"].as_array().expect("viewer items array");
    assert!(!items.is_empty(), "the viewer page should carry items");
    for item in items {
        assert!(
            item.get("workflow").is_none() && item.get("planning").is_none(),
            "a viewer's paged item kept an operator-only field: {item}"
        );
    }
}

fn page_path(cursor: Option<&str>) -> String {
    let base = format!(
        "{}?tag={PAGED_TAG}&limit={PAGE_SIZE}",
        http_paths::TASK_BOARD_ITEMS
    );
    match cursor {
        Some(cursor) => format!("{base}&cursor={cursor}"),
        None => base,
    }
}

fn assert_revisions_match_the_page(page: &Value, ids: &[String], page_number: usize) {
    let revisions = page["item_revisions"]
        .as_object()
        .expect("viewer item revisions");
    assert_eq!(
        revisions.len(),
        ids.len(),
        "page {page_number} carried revisions for a different set than its items"
    );
    for id in ids {
        assert!(
            revisions.contains_key(id),
            "page {page_number} returned {id} without its revision"
        );
    }
}

fn item_ids(response: &Value) -> Vec<String> {
    response["items"]
        .as_array()
        .expect("task board items array")
        .iter()
        .map(|item| item["id"].as_str().expect("item id").to_string())
        .collect()
}
