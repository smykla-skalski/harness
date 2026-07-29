//! Task-board item-command daemon-routing coverage.
//!
//! The id-escape rejection tests prove a path-separator or `..` segment never
//! reaches the daemon at all. The page-walk tests exercise
//! `item_commands::list_task_board_items`/`list_task_board_items_page`
//! directly against a scripted fake HTTP daemon, because the behavior under
//! test - stable query-string ordering, cursor-repeat and empty-cursor
//! detection, and the page-count cap - lives entirely in that walk and would
//! otherwise only be observable by parsing stdout off `Execute::execute()`.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use harness_workspace::command_context::{AppContext, Execute};

use harness::task_board::TaskBoardItem;
use harness::task_board::transport::item_args::TaskBoardItemFieldArgs;
use harness::task_board::transport::item_commands::{
    TASK_BOARD_LIST_MAX_PAGES, list_task_board_items,
};
use harness::task_board::transport::{
    TaskBoardDeleteArgs, TaskBoardUpdateArgs, TaskBoardUpdateClearEstimateArgs,
    TaskBoardUpdateClearLinkArgs, TaskBoardUpdateClearStateArgs,
};
use harness::task_board::types::{AgentMode, TaskBoardPriority, TaskBoardStatus};
use harness::task_board::wire::TaskBoardListItemsRequest;
use harness_daemon_client::DaemonClient;

fn empty_fields() -> TaskBoardItemFieldArgs {
    TaskBoardItemFieldArgs {
        external_ref: Vec::new(),
        planning_summary: None,
        approved_by: None,
        approved_at: None,
        workflow_execution_id: None,
        workflow_status: None,
        workflow_current_step_id: None,
        workflow_attempts: None,
        workflow_branch: None,
        workflow_worktree: None,
        workflow_pr_number: None,
        workflow_pr_url: None,
        workflow_last_error: None,
        workflow_policy_trace_id: Vec::new(),
        session_id: None,
        work_item_id: None,
        estimated_tokens: None,
        estimated_cost_microusd: None,
    }
}

/// A daemon route path is one URL segment per `{item_id}` placeholder; an
/// id smuggling a path separator or `..` would target a different route
/// than the one asked for, since neither `item_path` nor the leaf client
/// URL-encodes it.
#[test]
fn delete_rejects_an_id_that_would_escape_its_path_segment() {
    let error = TaskBoardDeleteArgs {
        id: "../orchestrator/stop".to_string(),
    }
    .execute(&AppContext)
    .expect_err("an id with a path separator must be rejected before any request is sent");
    assert!(error.to_string().contains("../orchestrator/stop"));
}

#[test]
fn update_rejects_an_id_that_would_escape_its_path_segment() {
    let error = TaskBoardUpdateArgs {
        id: "foo/../bar".to_string(),
        title: None,
        body: None,
        status: None,
        priority: None,
        agent_mode: None,
        kind: None,
        tag: Vec::new(),
        project_id: None,
        target_project_type: Vec::new(),
        parent_id: None,
        fields: empty_fields(),
        clear_links: TaskBoardUpdateClearLinkArgs {
            clear_project: false,
            clear_session: false,
            clear_work_item: false,
            clear_parent: false,
        },
        clear_estimates: TaskBoardUpdateClearEstimateArgs {
            clear_estimated_tokens: false,
            clear_estimated_cost_microusd: false,
        },
        clear_state: TaskBoardUpdateClearStateArgs {
            clear_external_refs: false,
            clear_planning: false,
            clear_workflow: false,
        },
    }
    .execute(&AppContext)
    .expect_err("an id with a path separator must be rejected before any request is sent");
    assert!(error.to_string().contains("foo/../bar"));
}

fn client_with(endpoint: String) -> DaemonClient {
    DaemonClient::test_client(endpoint, "test-token")
}

fn read_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .expect("read timeout");
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8(buffer).expect("utf8 request")
}

fn write_response(stream: &mut TcpStream, status: &str, content_type: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes()).expect("write");
    stream.flush().expect("flush");
}

fn spawn_mock(
    response_status: &'static str,
    response_body: String,
) -> (String, Arc<Mutex<String>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let request_line = Arc::new(Mutex::new(String::new()));
    let captured = Arc::clone(&request_line);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_request(&mut stream);
        *captured.lock().expect("request capture") =
            request.lines().next().unwrap_or_default().to_string();
        write_response(
            &mut stream,
            response_status,
            "application/json",
            &response_body,
        );
    });
    (endpoint, request_line, handle)
}

/// Serve one scripted response per request and record every request
/// line, for a walk that makes more than one round trip.
fn spawn_mock_sequence(
    responses: Vec<String>,
) -> (String, Arc<Mutex<Vec<String>>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let request_lines = Arc::new(Mutex::new(Vec::new()));
    let captured = Arc::clone(&request_lines);
    let handle = thread::spawn(move || {
        for response in responses {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_request(&mut stream);
            captured
                .lock()
                .expect("request capture")
                .push(request.lines().next().unwrap_or_default().to_string());
            write_response(&mut stream, "200 OK", "application/json", &response);
        }
    });
    (endpoint, request_lines, handle)
}

fn item() -> TaskBoardItem {
    TaskBoardItem::new(
        "task-1".into(),
        "Database task".into(),
        "body".into(),
        "2026-07-11T00:00:00Z".into(),
    )
}

fn page_of(ids: &[&str], next_cursor: Option<&str>) -> String {
    page_of_at(ids, next_cursor, 9)
}

fn page_of_at(ids: &[&str], next_cursor: Option<&str>, items_change_seq: i64) -> String {
    let items = ids
        .iter()
        .map(|id| {
            let mut item = item();
            item.id = (*id).to_string();
            item
        })
        .collect::<Vec<_>>();
    let mut page = serde_json::json!({
        "items": items,
        "items_change_seq": items_change_seq,
        "total_matched": ids.len(),
    });
    if let Some(cursor) = next_cursor {
        page["next_cursor"] = serde_json::json!(cursor);
    }
    page.to_string()
}

#[test]
fn list_serializes_status_as_query() {
    let response = serde_json::json!({ "items": [item()] }).to_string();
    let (endpoint, request_line, handle) = spawn_mock("200 OK", response);

    let items = list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest {
            status: Some(TaskBoardStatus::Inbox),
            ..TaskBoardListItemsRequest::default()
        },
    )
    .expect("list items");
    handle.join().expect("server");

    assert_eq!(items.len(), 1);
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items?status=inbox&limit=500 HTTP/1.1"
    );
}

/// Proves `task_board_list_query`'s enum-facet/text/page-query ordering:
/// status, priority, and `agent_mode` first, then `project_id`/`tag`/`query`,
/// then `limit`/`cursor` last.
#[test]
fn list_serializes_every_facet_as_query_in_a_stable_order() {
    let response = serde_json::json!({ "items": [item()] }).to_string();
    let (endpoint, request_line, handle) = spawn_mock("200 OK", response);

    list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest {
            status: Some(TaskBoardStatus::Todo),
            priority: Some(TaskBoardPriority::High),
            agent_mode: Some(AgentMode::Planning),
            project_id: Some("project-alpha".into()),
            tags: vec!["backend".into(), "urgent".into()],
            query: Some("widget".into()),
            limit: Some(25),
            cursor: None,
        },
    )
    .expect("list items");
    handle.join().expect("server");

    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items?status=todo&priority=high&agent_mode=planning\
         &project_id=project-alpha&tag=backend&tag=urgent&query=widget&limit=25 HTTP/1.1"
    );
}

/// The daemon bounds every page, so the plain list call has to ask for
/// the rest or every caller silently reads a truncated board.
#[test]
fn list_walks_every_page_until_the_cursor_runs_out() {
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

    let items = list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest::default(),
    )
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
            "GET /v1/task-board/items?limit=500 HTTP/1.1",
            "GET /v1/task-board/items?limit=500&cursor=cursor-2 HTTP/1.1",
        ]
    );
}

/// A cursor that names the same resume point twice can never drain, so
/// the walk has to stop and say why instead of fetching that page
/// forever.
#[test]
fn list_refuses_a_cursor_that_never_advances() {
    let page = serde_json::json!({
        "items": [item()],
        "total_matched": 2,
        "next_cursor": "cursor-stuck",
    })
    .to_string();
    let (endpoint, request_lines, handle) = spawn_mock_sequence(vec![page.clone(), page]);

    let error = list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest::default(),
    )
    .expect_err("a stalled cursor must fail rather than loop");
    handle.join().expect("server");

    assert!(
        error.to_string().contains("cursor-stuck"),
        "unexpected: {error}"
    );
    assert_eq!(request_lines.lock().expect("request lines").len(), 2);
}

/// The daemon never pairs a cursor with an empty page, so that shape
/// means a board this client cannot finish reading - and a `Vec` cannot
/// say so.
#[test]
fn list_refuses_a_cursor_with_no_items() {
    let first = serde_json::json!({
        "items": [item()],
        "total_matched": 2,
        "next_cursor": "cursor-2",
    })
    .to_string();
    let empty = serde_json::json!({ "items": [], "next_cursor": "cursor-3" }).to_string();
    let (endpoint, _request_lines, handle) = spawn_mock_sequence(vec![first, empty]);

    let error = list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest::default(),
    )
    .expect_err("an empty page with a cursor must not read as the whole board");
    handle.join().expect("server");

    assert!(
        error.to_string().contains("cursor with no items"),
        "unexpected: {error}"
    );
}

/// Sequence-bound cursors prevent overlap in valid responses. A
/// malformed overlapping page still must not hand one id back twice.
#[test]
fn list_walks_an_overlapping_row_only_once() {
    let (endpoint, _request_lines, handle) = spawn_mock_sequence(vec![
        page_of(&["task-1", "task-2", "task-3"], Some("cursor-2")),
        page_of(&["task-2", "task-3", "task-4"], None),
    ]);

    let items = list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest::default(),
    )
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

#[test]
fn list_refuses_a_changed_board_sequence_mid_walk() {
    let (endpoint, _request_lines, handle) = spawn_mock_sequence(vec![
        page_of_at(&["task-1"], Some("cursor-2"), 41),
        page_of_at(&["task-2"], None, 42),
    ]);

    let error = list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest::default(),
    )
    .expect_err("a mixed board snapshot must fail");
    handle.join().expect("server");

    assert!(
        error.to_string().contains("changed from sequence 41 to 42"),
        "unexpected: {error}"
    );
}

/// Refusing a repeated cursor only catches a resume point that stalls on
/// the very next page. A daemon that keeps offering one more distinct
/// cursor has to hit a ceiling, or the walk grows without bound.
#[test]
fn list_stops_at_the_page_cap_when_a_read_never_drains() {
    // Exactly one response per allowed page, so the walk must give up on
    // its own rather than ask for a page the mock never scripted.
    let responses = (0..TASK_BOARD_LIST_MAX_PAGES)
        .map(|index| {
            page_of(
                &[&format!("task-{index}")],
                Some(&format!("cursor-{index}")),
            )
        })
        .collect::<Vec<_>>();
    let (endpoint, request_lines, handle) = spawn_mock_sequence(responses);

    let error = list_task_board_items(
        &client_with(endpoint),
        &TaskBoardListItemsRequest::default(),
    )
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
