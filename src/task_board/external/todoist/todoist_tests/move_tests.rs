use std::io::ErrorKind;
use std::time::{Duration, Instant};

use serde_json::json;

use super::*;

#[tokio::test]
async fn todoist_project_only_update_uses_move_endpoint_and_response() {
    let (endpoint, captured, handle) = spawn_json_mock(
        r#"{"id":"remote-1","content":"Title","description":"Body","project_id":"project-destination","updated_at":"revision-move"}"#,
    );
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Title", "Body", Some("project-destination"));
    let move_request = TodoistMoveTaskRequest {
        project_id: "project-destination".into(),
    };
    let expected_request_id = TodoistRequestIntent::Move {
        item: &item,
        external_id: "remote-1",
        request: &move_request,
    }
    .request_id();

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Project]),
        )
        .await
        .expect("move task");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::Applied {
        reference,
        provider_revision,
    } = outcome
    else {
        panic!("move must be applied");
    };
    assert_eq!(provider_revision.as_deref(), Some("revision-move"));
    assert_eq!(
        reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/tasks/remote-1/move");
    assert_eq!(
        body_json(&captured.body),
        json!({"project_id": "project-destination"})
    );
    assert_eq!(captured.authorization.as_deref(), Some("Bearer token"));
    assert_eq!(
        captured.request_id.as_deref(),
        Some(expected_request_id.as_str())
    );
}

#[tokio::test]
async fn todoist_combined_metadata_then_move_returns_move_truth() {
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        (
            "200 OK",
            r#"{"id":"remote-1","content":"Updated","description":"Body","project_id":"project-source","updated_at":"revision-metadata"}"#,
        ),
        (
            "200 OK",
            r#"{"id":"remote-1","content":"Updated","description":"Body","project_id":"project-destination","updated_at":"revision-move"}"#,
        ),
    ]);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Updated", "Body", Some("project-destination"));

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title, ExternalSyncField::Project]),
        )
        .await
        .expect("update metadata and move task");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::Applied {
        reference,
        provider_revision,
    } = outcome
    else {
        panic!("combined update must be applied");
    };
    assert_eq!(provider_revision.as_deref(), Some("revision-move"));
    assert_eq!(
        reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].path, "/tasks/remote-1");
    assert_eq!(body_json(&captured[0].body), json!({"content": "Updated"}));
    assert_eq!(captured[1].path, "/tasks/remote-1/move");
    assert_eq!(
        body_json(&captured[1].body),
        json!({"project_id": "project-destination"})
    );
    assert!(captured.iter().all(|request| request.request_id.is_some()));
    assert_ne!(captured[0].request_id, captured[1].request_id);
}

#[tokio::test]
async fn todoist_reopen_then_metadata_then_move_preserves_final_truth() {
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        ("200 OK", "{}"),
        (
            "200 OK",
            r#"{"id":"remote-1","content":"Updated","description":"Body","project_id":"project-source","updated_at":"revision-metadata"}"#,
        ),
        (
            "200 OK",
            r#"{"id":"remote-1","content":"Updated","description":"Body","project_id":"project-destination","updated_at":"revision-move"}"#,
        ),
    ]);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut item = local_item("Updated", "Body", Some("project-destination"));
    item.status = TaskBoardStatus::InProgress;

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![
                ExternalSyncField::Status,
                ExternalSyncField::Title,
                ExternalSyncField::Project,
            ]),
        )
        .await
        .expect("reopen, update metadata, and move task");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::Applied {
        reference,
        provider_revision,
    } = outcome
    else {
        panic!("combined update must be applied");
    };
    assert_eq!(provider_revision.as_deref(), Some("revision-move"));
    assert_eq!(
        reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    let captured = captured.lock().expect("captured requests");
    assert_eq!(
        captured
            .iter()
            .map(|request| request.path.as_str())
            .collect::<Vec<_>>(),
        vec![
            "/tasks/remote-1/reopen",
            "/tasks/remote-1",
            "/tasks/remote-1/move",
        ]
    );
}

#[tokio::test]
async fn todoist_project_update_without_destination_fails_before_remote_call() {
    let (endpoint, captured, handle) = spawn_optional_json_mock();
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Title", "Body", None);

    let error = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Project]),
        )
        .await
        .expect_err("missing project destination must fail");

    handle.join().expect("mock server");
    assert!(error.to_string().contains("destination project ID"));
    assert!(captured.lock().expect("captured request").is_none());
}

fn spawn_optional_json_mock() -> (
    String,
    Arc<Mutex<Option<CapturedRequest>>>,
    thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    listener.set_nonblocking(true).expect("nonblocking");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(None));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_millis(200);
        while Instant::now() < deadline {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let request = read_http_request(&mut stream);
                    *captured_clone.lock().expect("captured request") =
                        Some(capture_request(&request));
                    write_json_response(
                        &mut stream,
                        r#"{"id":"remote-1","content":"Title","project_id":"project-destination"}"#,
                    );
                    return;
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("accept request: {error}"),
            }
        }
    });
    (endpoint, captured, handle)
}
