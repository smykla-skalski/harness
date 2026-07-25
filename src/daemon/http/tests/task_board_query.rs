use reqwest::StatusCode;
use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::{
    TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
};

use super::task_board_route_parity_support::{get_json, post_json, serve_http, ws_result, ws_rpc};

const SEEDED_ITEMS: usize = 12;

#[test]
fn task_board_list_filters_by_facet_text_and_page_over_http_and_websocket() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(run_task_board_query_flow());
    });
}

#[test]
fn task_board_cursors_stay_bounded_and_reject_a_changed_board() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(run_cursor_boundary_flow());
    });
}

async fn run_cursor_boundary_flow() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let long_id = "a".repeat(TASK_BOARD_LIST_MAX_CURSOR_CHARS * 2);
    for (id, title) in [(long_id.as_str(), "Long id"), ("z-next", "Next")] {
        post_json(
            &client,
            &base_url,
            http_paths::TASK_BOARD_ITEMS,
            json!({ "id": id, "title": title }),
        )
        .await;
    }

    let first = get_json(
        &client,
        &base_url,
        &format!("{}?limit=1", http_paths::TASK_BOARD_ITEMS),
    )
    .await;
    assert_eq!(item_ids(&first), vec![long_id]);
    let cursor = first["next_cursor"]
        .as_str()
        .expect("the first page has a cursor");
    assert!(cursor.len() <= TASK_BOARD_LIST_MAX_CURSOR_CHARS);
    let second = get_json(
        &client,
        &base_url,
        &format!("{}?limit=1&cursor={cursor}", http_paths::TASK_BOARD_ITEMS),
    )
    .await;
    assert_eq!(item_ids(&second), vec!["z-next"]);

    post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ITEMS,
        json!({ "id": "z-new", "title": "Mutation" }),
    )
    .await;
    let stale = client
        .get(format!(
            "{base_url}{}?limit=1&cursor={cursor}",
            http_paths::TASK_BOARD_ITEMS
        ))
        .bearer_auth("token")
        .send()
        .await
        .expect("send stale cursor");
    assert_eq!(stale.status(), StatusCode::BAD_REQUEST);
    let stale_body = stale.json::<Value>().await.expect("stale cursor body");
    assert!(
        stale_body["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("board changed"))
    );

    server.abort();
    let _ = server.await;
}

async fn run_task_board_query_flow() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    seed_board(&client, &base_url).await;

    assert_unfiltered_reads_are_bounded(&client, &base_url).await;
    assert_facets_narrow_the_selection(&client, &base_url).await;
    assert_text_matches_title_body_and_tags(&client, &base_url).await;
    assert_pages_cover_the_selection_exactly_once(&client, &base_url).await;
    assert_refused_pages_report_the_same_error_on_both_transports(&client, &base_url).await;

    server.abort();
    let _ = server.await;
}

/// Every item is distinct in exactly one facet so a filter that reads the
/// wrong field cannot accidentally return the expected count.
async fn seed_board(client: &reqwest::Client, base_url: &str) {
    for index in 0..SEEDED_ITEMS {
        let payload = json!({
            "id": format!("query-{index:02}"),
            "title": format!("Board item {index:02}"),
            "body": if index == 3 { "the cause was a race" } else { "routine body" },
            "status": "todo",
            "priority": if index == 4 { "critical" } else { "medium" },
            "agent_mode": if index == 5 { "planning" } else { "headless" },
            "project_id": if index == 6 { "project-beta" } else { "project-alpha" },
            "tags": if index == 7 { vec!["release-train", "backend"] } else { vec!["backend"] },
        });
        post_json(client, base_url, http_paths::TASK_BOARD_ITEMS, payload).await;
    }
}

async fn assert_unfiltered_reads_are_bounded(client: &reqwest::Client, base_url: &str) {
    let listed = get_json(client, base_url, http_paths::TASK_BOARD_ITEMS).await;

    assert_eq!(item_ids(&listed).len(), SEEDED_ITEMS);
    assert_eq!(listed["total_matched"], json!(SEEDED_ITEMS));
    assert!(
        listed["next_cursor"].is_null(),
        "a board under one page has nothing to resume"
    );
    assert!(
        SEEDED_ITEMS < TASK_BOARD_LIST_DEFAULT_LIMIT as usize,
        "this test only proves the bound when the seeded board fits one default page"
    );

    let capped = get_json(
        client,
        base_url,
        &format!(
            "{}?limit={}",
            http_paths::TASK_BOARD_ITEMS,
            TASK_BOARD_LIST_MAX_LIMIT
        ),
    )
    .await;
    assert_eq!(item_ids(&capped).len(), SEEDED_ITEMS);
}

async fn assert_facets_narrow_the_selection(client: &reqwest::Client, base_url: &str) {
    for (query, expected) in [
        ("priority=critical", vec!["query-04"]),
        ("agent_mode=planning", vec!["query-05"]),
        ("project_id=project-beta", vec!["query-06"]),
        ("tag=release-train", vec!["query-07"]),
        ("tag=release-train&tag=backend", vec!["query-07"]),
        ("tag=release-train&tag=absent", vec![]),
        ("status=done", vec![]),
    ] {
        let http = get_json(
            client,
            base_url,
            &format!("{}?{query}", http_paths::TASK_BOARD_ITEMS),
        )
        .await;
        assert_eq!(item_ids(&http), expected, "http {query}");
        assert_eq!(http["total_matched"], json!(expected.len()), "http {query}");
    }

    let websocket = ws_result(
        base_url,
        "req-task-board-facets",
        ws_methods::TASK_BOARD_LIST,
        json!({ "tags": ["release-train", "backend"] }),
    )
    .await;
    let http = get_json(
        client,
        base_url,
        &format!(
            "{}?tag=release-train&tag=backend",
            http_paths::TASK_BOARD_ITEMS
        ),
    )
    .await;
    assert_eq!(http, websocket, "both transports take the same facets");
}

async fn assert_text_matches_title_body_and_tags(client: &reqwest::Client, base_url: &str) {
    for (query, expected) in [
        ("query=item%2003", vec!["query-03"]),
        ("query=CAUSE", vec!["query-03"]),
        ("query=release-TRAIN", vec!["query-07"]),
        ("query=nothing%20matches%20this", vec![]),
    ] {
        let listed = get_json(
            client,
            base_url,
            &format!("{}?{query}", http_paths::TASK_BOARD_ITEMS),
        )
        .await;
        assert_eq!(item_ids(&listed), expected, "{query}");
    }

    let combined = get_json(
        client,
        base_url,
        &format!(
            "{}?query=Board%20item&priority=critical",
            http_paths::TASK_BOARD_ITEMS
        ),
    )
    .await;
    assert_eq!(item_ids(&combined), vec!["query-04"]);
}

/// The whole point of a cursor: two consecutive pages must cover the selection
/// without dropping or duplicating a row.
async fn assert_pages_cover_the_selection_exactly_once(client: &reqwest::Client, base_url: &str) {
    let mut walked = Vec::new();
    let mut cursor: Option<String> = None;
    let mut pages = 0;
    loop {
        let path = match &cursor {
            Some(cursor) => format!("{}?limit=5&cursor={cursor}", http_paths::TASK_BOARD_ITEMS),
            None => format!("{}?limit=5", http_paths::TASK_BOARD_ITEMS),
        };
        let page = get_json(client, base_url, &path).await;
        pages += 1;
        assert!(item_ids(&page).len() <= 5, "page {pages} broke the limit");
        assert_eq!(page["total_matched"], json!(SEEDED_ITEMS));
        walked.extend(item_ids(&page));
        match page["next_cursor"].as_str() {
            Some(next) => cursor = Some(next.to_string()),
            None => break,
        }
        assert!(pages < 10, "paging never terminated");
    }

    let unpaged = item_ids(&get_json(client, base_url, http_paths::TASK_BOARD_ITEMS).await);
    assert_eq!(pages, 3);
    assert_eq!(walked, unpaged, "paging changed the selection or its order");
}

async fn assert_refused_pages_report_the_same_error_on_both_transports(
    client: &reqwest::Client,
    base_url: &str,
) {
    for (http_query, ws_params) in [
        ("limit=0", json!({ "limit": 0 })),
        (
            "limit=100000",
            json!({ "limit": TASK_BOARD_LIST_MAX_LIMIT + 1 }),
        ),
        ("cursor=not-a-cursor", json!({ "cursor": "not-a-cursor" })),
        ("tag=%20", json!({ "tags": [" "] })),
    ] {
        let response = client
            .get(format!(
                "{base_url}{}?{http_query}",
                http_paths::TASK_BOARD_ITEMS
            ))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let status = response.status();
        let body = response.json::<Value>().await.expect("json response");
        assert_eq!(status, StatusCode::BAD_REQUEST, "{http_query}");

        let websocket = ws_rpc(
            base_url,
            "req-task-board-invalid-page",
            ws_methods::TASK_BOARD_LIST,
            ws_params,
        )
        .await;
        assert_eq!(websocket["error"]["status_code"].as_u64(), Some(400));
        assert_eq!(websocket["error"]["message"], body["error"]["message"]);
    }
}

fn item_ids(response: &Value) -> Vec<String> {
    response["items"]
        .as_array()
        .expect("items array")
        .iter()
        .map(|item| item["id"].as_str().expect("item id").to_string())
        .collect()
}
