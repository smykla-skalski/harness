use uuid::Uuid;

use super::*;

#[test]
fn todoist_status_intents_share_explicit_close_and_reopen_identities() {
    let base_item = local_item("Title", "Body", None);
    let non_done_statuses = [
        TaskBoardStatus::Backlog,
        TaskBoardStatus::Todo,
        TaskBoardStatus::Planning,
        TaskBoardStatus::InProgress,
        TaskBoardStatus::AgenticReview,
        TaskBoardStatus::Testing,
        TaskBoardStatus::InReview,
        TaskBoardStatus::ToReview,
        TaskBoardStatus::HumanRequired,
        TaskBoardStatus::Failed,
        TaskBoardStatus::New,
        TaskBoardStatus::PlanReview,
        TaskBoardStatus::NeedsYou,
        TaskBoardStatus::Blocked,
    ];
    let reopen_ids = non_done_statuses.map(|status| {
        let mut item = base_item.clone();
        item.status = status;
        let action = TodoistStatusAction::for_status(status);
        assert!(action == TodoistStatusAction::Reopen);
        assert_eq!(action.endpoint("remote-1"), "tasks/remote-1/reopen");
        TodoistRequestIntent::Status {
            item: &item,
            external_id: "remote-1",
            action,
        }
        .request_id()
    });
    assert!(reopen_ids.windows(2).all(|ids| ids[0] == ids[1]));

    let close = TodoistStatusAction::for_status(TaskBoardStatus::Done);
    let mut done_item = base_item;
    done_item.status = TaskBoardStatus::Done;
    assert!(close == TodoistStatusAction::Close);
    assert_eq!(close.endpoint("remote-1"), "tasks/remote-1/close");
    let close_id = TodoistRequestIntent::Status {
        item: &done_item,
        external_id: "remote-1",
        action: close,
    }
    .request_id();
    assert_ne!(reopen_ids[0], close_id);
}

#[test]
fn todoist_request_ids_hash_only_explicit_intent_inputs() {
    let item = local_item("Title", "Body", Some("project-1"));
    let create_request = TodoistCreateTaskRequest {
        content: item.title.clone(),
        description: non_empty_body(&item.body),
        project_id: item.project_id.clone(),
    };
    let create_id = TodoistRequestIntent::Create {
        item: &item,
        request: &create_request,
    }
    .request_id();
    assert_eq!(
        create_id,
        TodoistRequestIntent::Create {
            item: &item,
            request: &create_request,
        }
        .request_id()
    );
    assert_v5_rfc4122(&create_id);

    let edited = local_item("Edited title", "Body", Some("project-1"));
    let edited_request = TodoistCreateTaskRequest {
        content: edited.title.clone(),
        description: non_empty_body(&edited.body),
        project_id: edited.project_id.clone(),
    };
    assert_ne!(
        create_id,
        TodoistRequestIntent::Create {
            item: &edited,
            request: &edited_request,
        }
        .request_id()
    );

    let metadata = TodoistUpdateTaskRequest {
        content: Some("Updated".into()),
        description: None,
    };
    let metadata_id = TodoistRequestIntent::Metadata {
        item: &item,
        external_id: "remote-1",
        request: &metadata,
    }
    .request_id();
    assert_v5_rfc4122(&metadata_id);
    assert_ne!(create_id, metadata_id);

    let move_request = TodoistMoveTaskRequest {
        project_id: "project-2".into(),
    };
    let move_id = TodoistRequestIntent::Move {
        item: &item,
        external_id: "remote-1",
        request: &move_request,
    }
    .request_id();
    assert_v5_rfc4122(&move_id);
    assert_ne!(move_id, metadata_id);

    let delete_id = TodoistRequestIntent::Delete {
        item: &item,
        external_id: "remote-1",
    }
    .request_id();
    assert_v5_rfc4122(&delete_id);
    assert_ne!(delete_id, metadata_id);
}

#[test]
fn todoist_metadata_and_move_request_ids_advance_with_local_revision() {
    let item = local_item("Title", "Body", None);
    let mut later = item.clone();
    later.updated_at = "2026-05-15T00:01:00Z".into();
    let metadata = TodoistUpdateTaskRequest {
        content: Some("Updated".into()),
        description: None,
    };

    let metadata_id = TodoistRequestIntent::Metadata {
        item: &item,
        external_id: "remote-1",
        request: &metadata,
    }
    .request_id();
    assert_eq!(
        metadata_id,
        TodoistRequestIntent::Metadata {
            item: &item,
            external_id: "remote-1",
            request: &metadata,
        }
        .request_id()
    );
    assert_ne!(
        metadata_id,
        TodoistRequestIntent::Metadata {
            item: &later,
            external_id: "remote-1",
            request: &metadata,
        }
        .request_id()
    );

    let move_request = TodoistMoveTaskRequest {
        project_id: "project-2".into(),
    };
    let move_id = TodoistRequestIntent::Move {
        item: &item,
        external_id: "remote-1",
        request: &move_request,
    }
    .request_id();
    assert_eq!(
        move_id,
        TodoistRequestIntent::Move {
            item: &item,
            external_id: "remote-1",
            request: &move_request,
        }
        .request_id()
    );
    assert_ne!(
        move_id,
        TodoistRequestIntent::Move {
            item: &later,
            external_id: "remote-1",
            request: &move_request,
        }
        .request_id()
    );
}

#[test]
fn todoist_status_and_delete_request_ids_advance_with_local_revision() {
    let item = local_item("Title", "Body", None);
    let mut later = item.clone();
    later.updated_at = "2026-05-15T00:01:00Z".into();
    let close_id = TodoistRequestIntent::Status {
        item: &item,
        external_id: "remote-1",
        action: TodoistStatusAction::Close,
    }
    .request_id();
    assert_eq!(
        close_id,
        TodoistRequestIntent::Status {
            item: &item,
            external_id: "remote-1",
            action: TodoistStatusAction::Close,
        }
        .request_id()
    );
    assert_ne!(
        close_id,
        TodoistRequestIntent::Status {
            item: &later,
            external_id: "remote-1",
            action: TodoistStatusAction::Close,
        }
        .request_id()
    );

    let delete_id = TodoistRequestIntent::Delete {
        item: &item,
        external_id: "remote-1",
    }
    .request_id();
    assert_eq!(
        delete_id,
        TodoistRequestIntent::Delete {
            item: &item,
            external_id: "remote-1",
        }
        .request_id()
    );
    assert_ne!(
        delete_id,
        TodoistRequestIntent::Delete {
            item: &later,
            external_id: "remote-1",
        }
        .request_id()
    );
}

#[tokio::test]
async fn todoist_write_requests_send_intent_request_ids() {
    assert_create_headers().await;
    assert_metadata_headers().await;
    assert_move_headers().await;
    assert_status_headers().await;
    assert_delete_headers().await;
}

async fn assert_create_headers() {
    let (endpoint, captured, handle) = spawn_json_mock(
        r#"{"id":"remote-1","content":"Title","description":"Body","project_id":"project-1"}"#,
    );
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let item = local_item("Title", "Body", Some("project-1"));
    let request = TodoistCreateTaskRequest {
        content: item.title.clone(),
        description: non_empty_body(&item.body),
        project_id: item.project_id.clone(),
    };
    let expected = TodoistRequestIntent::Create {
        item: &item,
        request: &request,
    }
    .request_id();

    client.push_task(&item).await.expect("create task");

    handle.join().expect("mock server");
    assert_headers(&captured.lock().expect("captured request"), &expected);
}

async fn assert_metadata_headers() {
    let (endpoint, captured, handle) = spawn_json_mock(
        r#"{"id":"remote-1","content":"Updated","description":"Body","project_id":"project-1","updated_at":null}"#,
    );
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Updated", "Body", None);
    let request = TodoistUpdateTaskRequest {
        content: Some("Updated".into()),
        description: None,
    };
    let expected = TodoistRequestIntent::Metadata {
        item: &item,
        external_id: "remote-1",
        request: &request,
    }
    .request_id();

    client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title]),
        )
        .await
        .expect("update metadata");

    handle.join().expect("mock server");
    assert_headers(&captured.lock().expect("captured request"), &expected);
}

async fn assert_move_headers() {
    let (endpoint, captured, handle) = spawn_json_mock(
        r#"{"id":"remote-1","content":"Title","project_id":"project-2","updated_at":"revision-move"}"#,
    );
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Title", "Body", Some("project-2"));
    let request = TodoistMoveTaskRequest {
        project_id: "project-2".into(),
    };
    let expected = TodoistRequestIntent::Move {
        item: &item,
        external_id: "remote-1",
        request: &request,
    }
    .request_id();

    client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Project]),
        )
        .await
        .expect("move task");

    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.path, "/tasks/remote-1/move");
    assert_headers(&captured, &expected);
}

async fn assert_status_headers() {
    let (endpoint, captured, handle) = spawn_status_mock();
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item_with_status(TaskBoardStatus::InProgress);
    let expected = TodoistRequestIntent::Status {
        item: &item,
        external_id: "remote-1",
        action: TodoistStatusAction::Reopen,
    }
    .request_id();

    client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Status]),
        )
        .await
        .expect("update status");

    handle.join().expect("mock server");
    assert_headers(&captured.lock().expect("captured request"), &expected);
}

async fn assert_delete_headers() {
    let (endpoint, captured, handle) = spawn_status_mock();
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Title", "Body", None);
    let expected = TodoistRequestIntent::Delete {
        item: &item,
        external_id: "remote-1",
    }
    .request_id();

    client
        .delete_task(&item, &reference)
        .await
        .expect("delete task");

    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.method, "DELETE");
    assert_eq!(captured.path, "/tasks/remote-1");
    assert_headers(&captured, &expected);
}

fn assert_headers(captured: &CapturedRequest, expected_request_id: &str) {
    assert_eq!(captured.authorization.as_deref(), Some("Bearer token"));
    assert_eq!(captured.request_id.as_deref(), Some(expected_request_id));
}

fn assert_v5_rfc4122(request_id: &str) {
    let parsed = Uuid::parse_str(request_id).expect("request id UUID");
    assert_eq!(parsed.as_bytes()[6] >> 4, 5);
    assert_eq!(parsed.as_bytes()[8] & 0xc0, 0x80);
}
