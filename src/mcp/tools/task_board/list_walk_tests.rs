use serde_json::json;

use super::{TaskBoardItemPages, page_params};

fn page(ids: &[&str], next_cursor: Option<&str>) -> serde_json::Value {
    let mut page = json!({
        "items": ids.iter().map(|id| json!({ "id": id })).collect::<Vec<_>>(),
        "items_change_seq": 9,
        "total_matched": 3,
        "progress_rollups": { "umbrella-1": { "done": 1 } },
        "item_revisions": ids.iter().map(|id| ((*id).to_string(), json!(1))).collect::<serde_json::Map<_, _>>(),
    });
    if let Some(cursor) = next_cursor {
        page["next_cursor"] = json!(cursor);
    }
    page
}

fn folded_ids(response: &serde_json::Value) -> Vec<String> {
    response["items"]
        .as_array()
        .expect("items array")
        .iter()
        .map(|item| item["id"].as_str().expect("item id").to_string())
        .collect()
}

#[test]
fn every_page_folds_into_one_response_that_keeps_the_board_wide_fields() {
    let mut pages = TaskBoardItemPages::default();

    assert_eq!(
        pages
            .absorb(&page(&["task-1", "task-2"], Some("cursor-2")))
            .expect("a shaped page"),
        Some("cursor-2".to_string())
    );
    assert_eq!(
        pages.absorb(&page(&["task-3"], None)).expect("a shaped page"),
        None
    );
    let response = pages.into_response();

    assert_eq!(folded_ids(&response), ["task-1", "task-2", "task-3"]);
    assert_eq!(response["total_matched"], json!(3));
    assert_eq!(
        response["item_revisions"],
        json!({ "task-1": 1, "task-2": 1, "task-3": 1 }),
        "revisions are page-scoped, so a merged read carries every page's"
    );
    assert_eq!(response["progress_rollups"]["umbrella-1"]["done"], json!(1));
    assert!(
        response.get("next_cursor").is_none(),
        "a drained walk answers the whole selection"
    );
}

/// Sequence-bound cursors prevent overlap in valid responses. If a malformed
/// daemon still overlaps pages, the walk must not hand an item out twice.
#[test]
fn an_item_repeated_by_an_overlapping_page_is_folded_once() {
    let mut pages = TaskBoardItemPages::default();
    let mut overlapping = page(&["task-2", "task-3", "task-4"], None);
    overlapping["item_revisions"]["task-2"] = json!(2);
    overlapping["item_revisions"]["task-3"] = json!(2);

    pages
        .absorb(&page(&["task-1", "task-2", "task-3"], Some("cursor-2")))
        .expect("a shaped page");
    pages.absorb(&overlapping).expect("a shaped page");
    let response = pages.into_response();

    assert_eq!(
        folded_ids(&response),
        ["task-1", "task-2", "task-3", "task-4"]
    );
    assert_eq!(
        response["item_revisions"],
        json!({ "task-1": 1, "task-2": 1, "task-3": 1, "task-4": 1 })
    );
}

#[test]
fn a_changed_board_sequence_refuses_the_page_walk() {
    let mut pages = TaskBoardItemPages::default();
    let mut changed = page(&["task-2"], None);
    changed["items_change_seq"] = json!(10);

    pages
        .absorb(&page(&["task-1"], Some("cursor-2")))
        .expect("first page");
    let error = pages
        .absorb(&changed)
        .expect_err("a mixed board snapshot must fail");

    assert!(
        format!("{error:?}").contains("changed during the page walk"),
        "unexpected: {error:?}"
    );
}

/// The walk folds on ids, so an item without one cannot be deduplicated and
/// would be free to arrive twice.
#[test]
fn an_item_without_an_id_fails_the_page() {
    let mut pages = TaskBoardItemPages::default();

    let error = pages
        .absorb(&json!({
            "items": [{ "title": "no id here" }],
            "items_change_seq": 9,
        }))
        .expect_err("an item without an id must not reach the merged response");
    assert!(
        format!("{error:?}").contains("no id"),
        "unexpected: {error:?}"
    );
}

/// A drained board is the one legitimate empty page, and it carries no cursor.
#[test]
fn a_drained_page_ends_the_walk() {
    let mut pages = TaskBoardItemPages::default();

    pages
        .absorb(&page(&["task-1"], Some("cursor-2")))
        .expect("a shaped page");

    assert_eq!(
        pages.absorb(&page(&[], None)).expect("a drained page"),
        None
    );
}

/// An empty page beside a cursor cannot be walked further, and the merged
/// response has nowhere to say the read stopped early, so it would answer as a
/// whole board.
#[test]
fn an_empty_page_beside_a_cursor_fails_rather_than_draining_the_walk() {
    let mut pages = TaskBoardItemPages::default();

    pages
        .absorb(&page(&["task-1"], Some("cursor-2")))
        .expect("a shaped page");

    let error = pages
        .absorb(&page(&[], Some("cursor-3")))
        .expect_err("an empty page beside a cursor must not read as drained");
    assert!(
        format!("{error:?}").contains("cursor-3"),
        "unexpected: {error:?}"
    );
}

/// A page missing its items array is a daemon this tool cannot read. Answering
/// it as a drained selection would report a protocol mismatch as an empty
/// board.
#[test]
fn a_page_without_an_items_array_fails_rather_than_reading_as_empty() {
    let mut pages = TaskBoardItemPages::default();

    for malformed in [json!(null), json!({}), json!({ "items": "nope" })] {
        let error = pages
            .absorb(&malformed)
            .expect_err("a malformed page must not read as a drained board");
        assert!(
            format!("{error:?}").contains("items array"),
            "unexpected: {error:?}"
        );
    }
}

#[test]
fn a_page_request_replaces_the_cursor_and_keeps_the_rest_of_the_selection() {
    let selection = json!({ "status": "todo", "tags": ["backend"] });

    let first = page_params(&selection, None).expect("first page params");
    assert_eq!(first, selection);

    let second = page_params(&selection, Some("cursor-2")).expect("second page params");
    assert_eq!(second["cursor"], json!("cursor-2"));
    assert_eq!(second["status"], json!("todo"));
    assert_eq!(second["tags"], json!(["backend"]));

    let third = page_params(&second, Some("cursor-3")).expect("third page params");
    assert_eq!(third["cursor"], json!("cursor-3"));
}
