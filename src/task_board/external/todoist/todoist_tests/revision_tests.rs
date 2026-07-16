use super::*;

#[tokio::test]
async fn todoist_combined_close_does_not_report_pre_close_revision() {
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        (
            "200 OK",
            r#"{"id":"remote-1","content":"Updated title","description":"Body","updated_at":"provider-revision-2"}"#,
        ),
        ("204 No Content", ""),
    ]);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut item = local_item("Updated title", "Body", None);
    item.status = TaskBoardStatus::Done;

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title, ExternalSyncField::Status]),
        )
        .await
        .expect("update metadata and close task");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::Applied {
        provider_revision, ..
    } = outcome
    else {
        panic!("update must be applied");
    };
    assert_eq!(provider_revision, None);
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].path, "/tasks/remote-1");
    assert_eq!(captured[1].path, "/tasks/remote-1/close");
    assert!(captured.iter().all(|request| request.request_id.is_some()));
    assert_ne!(captured[0].request_id, captured[1].request_id);
}

#[tokio::test]
async fn todoist_combined_reopen_returns_final_metadata_revision() {
    let (endpoint, captured, handle) = spawn_reopen_metadata_mock();
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let mut item = local_item("Updated title", "Body", None);
    item.status = TaskBoardStatus::Todo;

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title, ExternalSyncField::Status]),
        )
        .await
        .expect("reopen and update metadata");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::Applied {
        provider_revision, ..
    } = outcome
    else {
        panic!("update must be applied");
    };
    assert_eq!(provider_revision.as_deref(), Some("provider-revision-3"));
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].path, "/tasks/remote-1/reopen");
    assert_eq!(captured[1].path, "/tasks/remote-1");
}

#[tokio::test]
async fn todoist_metadata_write_without_revision_does_not_reuse_precondition() {
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        (
            "200 OK",
            r#"{"id":"remote-1","content":"Base title","description":"Body","updated_at":"provider-revision-1"}"#,
        ),
        (
            "200 OK",
            r#"{"id":"remote-1","content":"Updated title","description":"Body","project_id":"project-1","updated_at":null}"#,
        ),
    ]);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Updated title", "Body", None);

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title])
                .with_precondition_updated_at(Some("provider-revision-1".into())),
        )
        .await
        .expect("update metadata");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::Applied {
        provider_revision, ..
    } = outcome
    else {
        panic!("update must be applied");
    };
    assert_eq!(provider_revision, None);
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].path, "/tasks/remote-1");
    assert_eq!(captured[1].path, "/tasks/remote-1");
}

fn spawn_reopen_metadata_mock() -> (
    String,
    Arc<Mutex<Vec<CapturedRequest>>>,
    thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(Vec::new()));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            let captured_request = capture_request(&request);
            let is_reopen = captured_request.path.ends_with("/reopen");
            captured_clone
                .lock()
                .expect("captured requests")
                .push(captured_request);
            if is_reopen {
                write_http_response(&mut stream, "204 No Content", "");
            } else {
                write_http_response(
                    &mut stream,
                    "200 OK",
                    r#"{"id":"remote-1","content":"Updated title","description":"Body","updated_at":"provider-revision-3"}"#,
                );
            }
        }
    });
    (endpoint, captured, handle)
}
