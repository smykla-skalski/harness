use serde_json::json;

use super::{TaskBoardItemPages, page_params};

fn page(ids: &[&str], next_cursor: Option<&str>) -> serde_json::Value {
    let mut page = json!({
        "items": ids.iter().map(|id| json!({ "id": id })).collect::<Vec<_>>(),
        "total_matched": 3,
        "progress_rollups": { "umbrella-1": { "done": 1 } },
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
    assert_eq!(response["progress_rollups"]["umbrella-1"]["done"], json!(1));
    assert!(
        response.get("next_cursor").is_none(),
        "a drained walk answers the whole selection"
    );
}

/// A cursor whose anchor was deleted between two reads resumes at that anchor's
/// slot, which can re-serve a row an earlier page already returned. The walk
/// must not hand the same item to the caller twice.
#[test]
fn a_row_re_served_after_a_concurrent_delete_is_folded_once() {
    let mut pages = TaskBoardItemPages::default();

    pages
        .absorb(&page(&["task-1", "task-2", "task-3"], Some("cursor-2")))
        .expect("a shaped page");
    pages
        .absorb(&page(&["task-2", "task-3", "task-4"], None))
        .expect("a shaped page");

    assert_eq!(
        folded_ids(&pages.into_response()),
        ["task-1", "task-2", "task-3", "task-4"]
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

    let first = page_params(&selection, &None).expect("first page params");
    assert_eq!(first, selection);

    let second =
        page_params(&selection, &Some("cursor-2".to_string())).expect("second page params");
    assert_eq!(second["cursor"], json!("cursor-2"));
    assert_eq!(second["status"], json!("todo"));
    assert_eq!(second["tags"], json!(["backend"]));

    let third = page_params(&second, &Some("cursor-3".to_string())).expect("third page params");
    assert_eq!(third["cursor"], json!("cursor-3"));
}
