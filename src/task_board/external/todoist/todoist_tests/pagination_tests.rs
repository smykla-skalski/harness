use super::*;

#[tokio::test]
async fn todoist_pull_follows_encoded_cursor_and_filters_every_page() {
    let cursor = "page/2?token=alpha+beta=";
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        (
            "200 OK",
            r#"{
                "results": [
                    {"id":"first","content":"First match","project_id":"project-keep"},
                    {"id":"skip","content":"Skip","project_id":"project-skip"}
                ],
                "next_cursor":"page/2?token=alpha+beta="
            }"#,
        ),
        (
            "200 OK",
            r#"{
                "results": [
                    {"id":"second","content":"Second match","project_id":"project-keep"}
                ],
                "next_cursor":null
            }"#,
        ),
    ]);
    let mut client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    client.import_project_ids = vec!["project-keep".into()];

    let tasks = client.pull_tasks().await.expect("pull every page");

    handle.join().expect("mock server");
    assert_eq!(
        tasks
            .iter()
            .map(|task| task.reference.external_id.as_str())
            .collect::<Vec<_>>(),
        vec!["first", "second"]
    );
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].path, "/tasks");
    let page_url =
        reqwest::Url::parse(&format!("http://localhost{}", captured[1].path)).expect("page URL");
    assert_eq!(
        page_url
            .query_pairs()
            .find(|(name, _)| name == "cursor")
            .map(|(_, value)| value.into_owned())
            .as_deref(),
        Some(cursor)
    );
    assert!(captured[1].path.contains("%2F"));
    assert!(
        captured
            .iter()
            .all(|request| request.authorization.as_deref() == Some("Bearer token"))
    );
}

#[tokio::test]
async fn todoist_pull_rejects_repeated_cursor() {
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        ("200 OK", r#"{"results":[],"next_cursor":"repeat-cursor"}"#),
        ("200 OK", r#"{"results":[],"next_cursor":"repeat-cursor"}"#),
    ]);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");

    let error = client
        .pull_tasks()
        .await
        .expect_err("repeated cursor must fail closed");

    handle.join().expect("mock server");
    assert!(error.to_string().contains("repeated pagination cursor"));
    assert_eq!(captured.lock().expect("captured requests").len(), 2);
}

#[tokio::test]
async fn todoist_pull_rejects_missing_required_next_cursor() {
    let (endpoint, _captured, handle) =
        spawn_json_mock_response(r#"{"results":[{"id":"task-1","content":"Task"}]}"#);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");

    let result = client.pull_tasks().await;

    handle.join().expect("mock server");
    result.expect_err("missing next_cursor must fail closed");
}

#[tokio::test]
async fn todoist_pull_rejects_empty_next_cursor() {
    let (endpoint, _captured, handle) =
        spawn_json_mock_response(r#"{"results":[],"next_cursor":""}"#);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");

    let error = client
        .pull_tasks()
        .await
        .expect_err("empty next_cursor must fail closed");

    handle.join().expect("mock server");
    assert!(error.to_string().contains("empty pagination cursor"));
}

#[tokio::test]
async fn todoist_pull_rejects_malformed_next_cursor() {
    let (endpoint, _captured, handle) =
        spawn_json_mock_response(r#"{"results":[],"next_cursor":42}"#);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");

    let result = client.pull_tasks().await;

    handle.join().expect("mock server");
    result.expect_err("malformed next_cursor must fail closed");
}
