use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::json;
use tokio::sync::{broadcast, mpsc, oneshot};

use super::*;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::codex_transport::CodexTransport;
use crate::daemon::protocol::{
    CodexApprovalDecision, CodexApprovalRequest, CodexRunMode, StreamEvent,
};

#[tokio::test]
async fn initialize_sends_initialized_notification_before_thread_requests() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let worker = CodexRunWorker::new(
        controller_without_db(),
        running_snapshot_without_ids(),
        control_rx,
    );
    let sent = Arc::new(Mutex::new(Vec::new()));
    let recv = Arc::new(Mutex::new(VecDeque::from([json!({
        "id": 1,
        "result": {}
    })
    .to_string()])));
    let mut rpc = CodexJsonRpc::new(Box::new(FakeTransport {
        sent: Arc::clone(&sent),
        recv,
    }));

    worker
        .initialize(&mut rpc)
        .await
        .expect("initialize handshake should complete");

    let frames = sent.lock().expect("sent frames");
    let initialize: serde_json::Value =
        serde_json::from_str(frames.first().expect("initialize frame")).expect("initialize json");
    let initialized: serde_json::Value =
        serde_json::from_str(frames.get(1).expect("initialized frame")).expect("initialized json");
    assert_eq!(initialize["method"], json!(wire::METHOD_INITIALIZE));
    assert_eq!(initialized, json!({ "method": wire::METHOD_INITIALIZED }));
}

#[tokio::test]
async fn invalid_steer_ack_does_not_fail_worker_loop() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut worker = CodexRunWorker::new(
        controller_without_db(),
        running_snapshot_without_ids(),
        control_rx,
    );
    let mut rpc = CodexJsonRpc::new(Box::new(FakeTransport::default()));
    let (ack, receiver) = oneshot::channel();

    let should_stop = worker
        .handle_control(
            &mut rpc,
            CodexControlMessage::Steer {
                prompt: "more context".to_string(),
                ack,
            },
        )
        .await
        .expect("control handling should not fail the worker");

    assert!(!should_stop);
    assert!(
        receiver.await.expect("ack").is_err(),
        "invalid steer should report an action error"
    );
    assert_eq!(worker.snapshot.status, CodexRunStatus::Running);
}

#[tokio::test]
async fn unknown_approval_ack_does_not_fail_worker_loop() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut snapshot = running_snapshot_without_ids();
    snapshot.thread_id = Some("thread-1".to_string());
    snapshot.turn_id = Some("turn-1".to_string());
    snapshot.status = CodexRunStatus::WaitingApproval;
    let mut worker = CodexRunWorker::new(controller_without_db(), snapshot, control_rx);
    let mut rpc = CodexJsonRpc::new(Box::new(FakeTransport::default()));
    let (ack, receiver) = oneshot::channel();

    let should_stop = worker
        .handle_control(
            &mut rpc,
            CodexControlMessage::Approval {
                approval_id: "missing-approval".to_string(),
                decision: CodexApprovalDecision::Accept,
                ack,
            },
        )
        .await
        .expect("control handling should not fail the worker");

    assert!(!should_stop);
    assert!(
        receiver.await.expect("ack").is_err(),
        "unknown approval should report an action error"
    );
    assert_eq!(worker.snapshot.status, CodexRunStatus::WaitingApproval);
}

#[tokio::test]
async fn steer_ack_reports_app_server_error_without_failing_worker_loop() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut snapshot = running_snapshot_without_ids();
    snapshot.thread_id = Some("thread-1".to_string());
    snapshot.turn_id = Some("turn-1".to_string());
    let mut worker = CodexRunWorker::new(controller_without_db(), snapshot, control_rx);
    let recv = Arc::new(Mutex::new(VecDeque::from([json!({
        "id": 1,
        "error": {
            "code": -32602,
            "message": "turn is not steerable"
        }
    })
    .to_string()])));
    let mut rpc = CodexJsonRpc::new(Box::new(FakeTransport {
        recv,
        ..Default::default()
    }));
    let (ack, receiver) = oneshot::channel();

    let should_stop = worker
        .handle_control(
            &mut rpc,
            CodexControlMessage::Steer {
                prompt: "more context".to_string(),
                ack,
            },
        )
        .await
        .expect("control handling should not fail the worker");

    assert!(!should_stop);
    let error = receiver
        .await
        .expect("ack")
        .expect_err("app-server steer error should be reported to caller");
    assert!(error.to_string().contains("turn is not steerable"));
    assert_eq!(worker.snapshot.status, CodexRunStatus::Running);
}

#[test]
fn turn_completed_clears_pending_approval_state() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut snapshot = running_snapshot_without_ids();
    snapshot.status = CodexRunStatus::WaitingApproval;
    snapshot.pending_approvals.push(CodexApprovalRequest {
        approval_id: "approval-1".to_string(),
        request_id: "request-1".to_string(),
        kind: "command".to_string(),
        title: "Command approval requested".to_string(),
        detail: "Approve command".to_string(),
        thread_id: Some("thread-1".to_string()),
        turn_id: Some("turn-1".to_string()),
        item_id: Some("item-1".to_string()),
        cwd: Some("/tmp/harness".to_string()),
        command: Some("touch approved.txt".to_string()),
        file_path: None,
    });
    let mut worker = CodexRunWorker::new(controller_without_db(), snapshot, control_rx);
    worker.pending_approvals.insert(
        "approval-1".to_string(),
        vec![PendingApproval {
            request_id: json!(41),
            method: "item/commandExecution/requestApproval".to_string(),
            params: json!({ "itemId": "item-1" }),
        }],
    );

    let _ = worker.handle_turn_completed(Some("interrupted"), None);

    assert!(worker.snapshot.pending_approvals.is_empty());
    assert!(worker.pending_approvals.is_empty());
}

#[tokio::test]
async fn permission_approval_response_grants_requested_subset() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut snapshot = running_snapshot_without_ids();
    snapshot.thread_id = Some("thread-1".to_string());
    snapshot.turn_id = Some("turn-1".to_string());
    let mut worker = CodexRunWorker::new(controller_without_db(), snapshot, control_rx);
    let sent = Arc::new(Mutex::new(Vec::new()));
    let mut rpc = CodexJsonRpc::new(Box::new(FakeTransport {
        sent: Arc::clone(&sent),
        ..Default::default()
    }));
    let params = json!({
        "threadId": "thread-1",
        "turnId": "turn-1",
        "itemId": "permission-1",
        "permissions": {
            "fileSystem": {
                "write": ["/tmp/project"]
            }
        }
    });
    worker.pending_approvals.insert(
        "permission-1".to_string(),
        vec![PendingApproval {
            request_id: json!(41),
            method: "item/permissions/requestApproval".to_string(),
            params,
        }],
    );
    let (ack, receiver) = oneshot::channel();
    worker
        .handle_control(
            &mut rpc,
            CodexControlMessage::Approval {
                approval_id: "permission-1".to_string(),
                decision: CodexApprovalDecision::AcceptForSession,
                ack,
            },
        )
        .await
        .expect("approval should be sent");

    let _ = receiver.await.expect("approval ack");
    let frames = sent.lock().expect("sent frames");
    let response: serde_json::Value =
        serde_json::from_str(frames.last().expect("approval response frame"))
            .expect("json response");
    assert_eq!(response["id"], json!(41));
    assert_eq!(response["result"]["scope"], json!("session"));
    assert_eq!(
        response["result"]["permissions"],
        json!({
            "fileSystem": {
                "write": ["/tmp/project"]
            }
        })
    );
}

#[test]
fn agent_message_delta_updates_summary_without_event_row_when_throttled() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut worker = CodexRunWorker::new(
        controller_without_db(),
        running_snapshot_without_ids(),
        control_rx,
    );
    worker.last_delta_persist_at = Some(std::time::Instant::now());

    let should_stop = worker
        .handle_notification("item/agentMessage/delta", &json!({ "delta": "hello" }))
        .expect("delta notification should be handled");

    assert!(!should_stop);
    assert_eq!(worker.snapshot.latest_summary.as_deref(), Some("hello"));
    assert!(
        worker.snapshot.events.is_empty(),
        "delta streaming should not append persisted event rows"
    );
}

#[test]
fn child_thread_completion_does_not_finish_parent_worker() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut snapshot = running_snapshot_without_ids();
    snapshot.thread_id = Some("thread-parent".to_string());
    snapshot.turn_id = Some("turn-parent".to_string());
    let mut worker = CodexRunWorker::new(controller_without_db(), snapshot, control_rx);

    let should_stop = worker
        .handle_notification(
            "turn/completed",
            &json!({
                "threadId": "thread-child",
                "turn": {
                    "id": "turn-child",
                    "status": "completed"
                }
            }),
        )
        .expect("child completion should be ignored");

    assert!(!should_stop);
    assert_eq!(worker.snapshot.status, CodexRunStatus::Running);
    assert_eq!(worker.snapshot.thread_id.as_deref(), Some("thread-parent"));
    assert_eq!(worker.snapshot.turn_id.as_deref(), Some("turn-parent"));
    assert!(worker.snapshot.events.is_empty());
}

#[test]
fn completion_missing_active_notification_id_does_not_finish_worker() {
    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut snapshot = running_snapshot_without_ids();
    snapshot.thread_id = Some("thread-parent".to_string());
    snapshot.turn_id = Some("turn-parent".to_string());
    let mut worker = CodexRunWorker::new(controller_without_db(), snapshot, control_rx);
    let incomplete_notifications = [
        json!({
            "turn": { "id": "turn-parent", "status": "completed" }
        }),
        json!({
            "threadId": "thread-parent",
            "turn": { "status": "completed" }
        }),
    ];

    for params in incomplete_notifications {
        let should_stop = worker
            .handle_notification("turn/completed", &params)
            .expect("incomplete completion should be ignored");
        assert!(
            !should_stop,
            "missing active id matched notification: {params}"
        );
    }

    assert_eq!(worker.snapshot.status, CodexRunStatus::Running);
    assert!(worker.snapshot.events.is_empty());
}

#[tokio::test(start_paused = true)]
async fn startup_request_times_out_when_app_server_does_not_answer() {
    let task = tokio::spawn(with_startup_timeout("initialize", async {
        std::future::pending::<Result<(), CliError>>().await
    }));

    tokio::time::advance(STARTUP_REQUEST_TIMEOUT).await;
    let error = task
        .await
        .expect("timeout task should join")
        .expect_err("startup request should time out");

    assert!(
        error
            .to_string()
            .contains("codex app-server initialize did not respond within 30s"),
        "unexpected timeout error: {error}"
    );
}

fn controller_without_db() -> CodexControllerHandle {
    let (sender, _) = broadcast::channel::<StreamEvent>(8);
    CodexControllerHandle::new(sender, Arc::new(std::sync::OnceLock::new()), false)
}

fn running_snapshot_without_ids() -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: "codex-run-test".to_string(),
        session_id: "session-test".to_string(),
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        session_agent_id: None,
        display_name: Some("Codex".to_string()),
        project_dir: "/tmp/harness".to_string(),
        thread_id: None,
        turn_id: None,
        mode: CodexRunMode::Approval,
        status: CodexRunStatus::Running,
        prompt: "Investigate".to_string(),
        latest_summary: None,
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-04-09T10:00:00Z".to_string(),
        updated_at: "2026-04-09T10:00:00Z".to_string(),
        model: None,
        effort: None,
    }
}

#[derive(Default)]
struct FakeTransport {
    sent: Arc<Mutex<Vec<String>>>,
    recv: Arc<Mutex<VecDeque<String>>>,
}

#[async_trait]
impl CodexTransport for FakeTransport {
    async fn send(&mut self, frame: String) -> Result<(), CliError> {
        self.sent.lock().expect("sent lock").push(frame);
        Ok(())
    }

    async fn next_frame(&mut self) -> Result<Option<String>, CliError> {
        Ok(self.recv.lock().expect("recv lock").pop_front())
    }

    async fn shutdown(self: Box<Self>) -> Result<(), CliError> {
        Ok(())
    }
}
