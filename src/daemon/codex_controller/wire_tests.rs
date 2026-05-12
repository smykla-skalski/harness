use serde_json::json;

use super::{
    AppServerNotification, CompletedItem, ThreadParamsInput, initialize_params, parse_notification,
    thread_id_from_result, thread_params, turn_start_params,
};

#[test]
fn thread_params_serialize_harness_owned_app_server_shape() {
    let value = thread_params(ThreadParamsInput {
        cwd: "/tmp/project",
        sandbox: "read-only",
        approval_policy: "on-request",
        developer_instructions: "follow harness mode",
        thread_id: Some("thread-1"),
        model: Some("gpt-5.5"),
    })
    .expect("thread params serialize");

    assert_eq!(
        value,
        json!({
            "cwd": "/tmp/project",
            "sandbox": "read-only",
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "developerInstructions": "follow harness mode",
            "threadId": "thread-1",
            "model": "gpt-5.5",
        })
    );
}

#[test]
fn turn_start_params_serialize_text_input_and_sandbox_policy() {
    let value = turn_start_params(
        "thread-1",
        "/tmp/project",
        "hello",
        "never",
        json!({ "type": "readOnly" }),
        Some("gpt-5.5"),
        Some("high"),
    )
    .expect("turn params serialize");

    assert_eq!(
        value,
        json!({
            "threadId": "thread-1",
            "cwd": "/tmp/project",
            "input": [{ "type": "text", "text": "hello" }],
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandboxPolicy": { "type": "readOnly" },
            "model": "gpt-5.5",
            "effort": "high",
        })
    );
}

#[test]
fn notification_parser_extracts_handled_shapes_tolerantly() {
    assert_eq!(
        parse_notification("turn/started", &json!({ "turn": { "id": "turn-1" } })),
        AppServerNotification::TurnStarted {
            turn_id: Some("turn-1".to_string())
        }
    );
    assert_eq!(
        parse_notification(
            "item/completed",
            &json!({
                "item": {
                    "type": "agentMessage",
                    "text": "done",
                    "phase": "final_answer"
                }
            })
        ),
        AppServerNotification::ItemCompleted {
            item: CompletedItem {
                kind: Some("agentMessage".to_string()),
                text: Some("done".to_string()),
                phase: Some("final_answer".to_string()),
            }
        }
    );
    assert_eq!(
        parse_notification("turn/completed", &json!({ "turn": { "status": "failed" } })),
        AppServerNotification::TurnCompleted {
            status: Some("failed".to_string()),
            error_message: None,
        }
    );
}

#[test]
fn result_parsers_extract_ids_from_app_server_responses() {
    assert_eq!(
        thread_id_from_result(&json!({ "thread": { "id": "thread-1" } })),
        Some("thread-1".to_string())
    );
}

#[test]
fn initialize_params_enable_experimental_api() {
    let value = initialize_params("34.1.0").expect("initialize params serialize");
    assert_eq!(
        value,
        json!({
            "clientInfo": {
                "name": "harness-daemon",
                "title": "Harness daemon",
                "version": "34.1.0"
            },
            "capabilities": { "experimentalApi": true }
        })
    );
}
