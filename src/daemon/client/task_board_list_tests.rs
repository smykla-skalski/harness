use crate::daemon::protocol::TaskBoardListItemsRequest;
use crate::task_board::{AgentMode, TaskBoardPriority, TaskBoardStatus};

use super::task_board_list::TASK_BOARD_LIST_MAX_PAGES;
use super::task_board_tests::{client_with, item, spawn_mock, spawn_mock_sequence};

#[test]
fn task_board_list_serializes_status_as_query() {
    let response = serde_json::json!({ "items": [item()] }).to_string();
    let (endpoint, request_line, handle) = spawn_mock("200 OK", response);

    let items = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest {
            status: Some(TaskBoardStatus::Backlog),
            ..TaskBoardListItemsRequest::default()
        })
        .expect("list items");
    handle.join().expect("server");

    assert_eq!(items.len(), 1);
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items?status=backlog HTTP/1.1"
    );
}

#[test]
fn task_board_list_serializes_every_facet_as_query() {
    let response = serde_json::json!({ "items": [item()] }).to_string();
    let (endpoint, request_line, handle) = spawn_mock("200 OK", response);

    client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest {
            status: Some(TaskBoardStatus::Todo),
            priority: Some(TaskBoardPriority::High),
            agent_mode: Some(AgentMode::Planning),
            project_id: Some("project-alpha".into()),
            tags: vec!["backend".into(), "urgent".into()],
            query: Some("widget".into()),
            limit: Some(25),
            cursor: None,
        })
        .expect("list items");
    handle.join().expect("server");

    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items?status=todo&priority=high&agent_mode=planning\
         &project_id=project-alpha&tag=backend&tag=urgent&query=widget&limit=25 HTTP/1.1"
    );
}

/// The daemon bounds every page, so the plain list call has to ask for the
/// rest or every caller silently reads a truncated board.
#[test]
fn task_board_list_walks_every_page_until_the_cursor_runs_out() {
    let first = serde_json::json!({
        "items": [item()],
        "total_matched": 2,
        "next_cursor": "cursor-2",
    })
    .to_string();
    let mut second_item = item();
    second_item.id = "task-2".into();
    let second = serde_json::json!({ "items": [second_item], "total_matched": 2 }).to_string();
    let (endpoint, request_lines, handle) = spawn_mock_sequence(vec![first, second]);

    let items = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest::default())
        .expect("list items");
    handle.join().expect("server");

    assert_eq!(
        items
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["task-1", "task-2"]
    );
    assert_eq!(
        *request_lines.lock().expect("request lines"),
        [
            "GET /v1/task-board/items HTTP/1.1",
            "GET /v1/task-board/items?cursor=cursor-2 HTTP/1.1",
        ]
    );
}

/// A cursor that names the same resume point twice can never drain, so the
/// walk has to stop and say why instead of fetching that page forever.
#[test]
fn task_board_list_refuses_a_cursor_that_never_advances() {
    let page = serde_json::json!({
        "items": [item()],
        "total_matched": 2,
        "next_cursor": "cursor-stuck",
    })
    .to_string();
    let (endpoint, request_lines, handle) = spawn_mock_sequence(vec![page.clone(), page]);

    let error = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest::default())
        .expect_err("a stalled cursor must fail rather than loop");
    handle.join().expect("server");

    assert!(
        error.to_string().contains("cursor-stuck"),
        "unexpected: {error}"
    );
    assert_eq!(request_lines.lock().expect("request lines").len(), 2);
}

/// The daemon never pairs a cursor with an empty page, so that shape means a
/// board this client cannot finish reading - and a `Vec` cannot say so.
#[test]
fn task_board_list_refuses_a_cursor_with_no_items() {
    let first = serde_json::json!({
        "items": [item()],
        "total_matched": 2,
        "next_cursor": "cursor-2",
    })
    .to_string();
    let empty = serde_json::json!({ "items": [], "next_cursor": "cursor-3" }).to_string();
    let (endpoint, _request_lines, handle) = spawn_mock_sequence(vec![first, empty]);

    let error = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest::default())
        .expect_err("an empty page with a cursor must not read as the whole board");
    handle.join().expect("server");

    assert!(
        error.to_string().contains("cursor with no items"),
        "unexpected: {error}"
    );
}

/// A cursor whose anchor was deleted between two reads resumes at the slot that
/// anchor held, so a page can re-serve a row an earlier page already returned.
/// This call promises one whole board and every consumer keys on item id, so a
/// repeat has to be dropped rather than handed back twice.
#[test]
fn task_board_list_walks_a_re_served_row_only_once() {
    let (endpoint, _request_lines, handle) = spawn_mock_sequence(vec![
        page_of(&["task-1", "task-2", "task-3"], Some("cursor-2")),
        page_of(&["task-2", "task-3", "task-4"], None),
    ]);

    let items = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest::default())
        .expect("list items");
    handle.join().expect("server");

    assert_eq!(
        items
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["task-1", "task-2", "task-3", "task-4"]
    );
}

/// Refusing a repeated cursor only catches a resume point that stalls on the
/// very next page. A daemon that keeps offering one more distinct cursor has to
/// hit a ceiling, or the walk grows without bound.
#[test]
fn task_board_list_stops_at_the_page_cap_when_a_read_never_drains() {
    // Exactly one response per allowed page, so the walk must give up on its
    // own rather than ask for a page the mock never scripted.
    let responses = (0..TASK_BOARD_LIST_MAX_PAGES)
        .map(|index| {
            page_of(
                &[&format!("task-{index}")],
                Some(&format!("cursor-{index}")),
            )
        })
        .collect::<Vec<_>>();
    let (endpoint, request_lines, handle) = spawn_mock_sequence(responses);

    let error = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest::default())
        .expect_err("an undrainable read must fail rather than grow forever");
    handle.join().expect("server");

    assert!(
        error.to_string().contains("did not drain"),
        "unexpected: {error}"
    );
    assert_eq!(
        request_lines.lock().expect("request lines").len(),
        TASK_BOARD_LIST_MAX_PAGES,
        "the walk asked for a different number of pages than its own cap"
    );
}

fn page_of(ids: &[&str], next_cursor: Option<&str>) -> String {
    let items = ids
        .iter()
        .map(|id| {
            let mut item = item();
            item.id = (*id).to_string();
            item
        })
        .collect::<Vec<_>>();
    let mut page = serde_json::json!({ "items": items, "total_matched": ids.len() });
    if let Some(cursor) = next_cursor {
        page["next_cursor"] = serde_json::json!(cursor);
    }
    page.to_string()
}
