use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tokio::sync::{broadcast, mpsc, oneshot};

use super::*;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::codex_transport::CodexTransport;
use crate::daemon::protocol::{CodexRunMode, StreamEvent};

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

fn controller_without_db() -> CodexControllerHandle {
    let (sender, _) = broadcast::channel::<StreamEvent>(8);
    CodexControllerHandle::new(sender, Arc::new(std::sync::OnceLock::new()), false)
}

fn running_snapshot_without_ids() -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: "codex-run-test".to_string(),
        session_id: "session-test".to_string(),
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
}

#[async_trait]
impl CodexTransport for FakeTransport {
    async fn send(&mut self, frame: String) -> Result<(), CliError> {
        self.sent.lock().expect("sent lock").push(frame);
        Ok(())
    }

    async fn next_frame(&mut self) -> Result<Option<String>, CliError> {
        Ok(None)
    }

    async fn shutdown(self: Box<Self>) -> Result<(), CliError> {
        Ok(())
    }
}
