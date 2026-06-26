//! Golden-path regression net for the Codex app-server swarm substrate.
//!
//! This drives the real `CodexRunWorker` through `run_with_transport` against a
//! scripted in-process Codex `app-server` (no `codex` binary, no Mac, no
//! network), asserting the substrate's core contract: an assigned task prompt
//! reaches `turn/start` and the run completes cleanly. It is the first slice of
//! the M0 golden-path harness described in `docs/FOCUS.md`; later slices extend
//! it to dispatch-ack, review, and land stages.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::super::worker::CodexRunWorker;
use super::test_support::{
    codex_run_snapshot, controller_with_session_state, sample_session_state_with_codex_agent,
};
use crate::daemon::codex_transport::CodexTransport;
use crate::daemon::protocol::CodexRunStatus;
use crate::errors::CliError;
use crate::session::types::AgentStatus;

/// A scripted, request-aware Codex `app-server` double. Unlike a fixed-queue
/// fake, it inspects each outbound JSON-RPC frame and synthesizes the matching
/// reply, plus a terminal `turn/completed` notification after `turn/start` so
/// the worker's event loop terminates deterministically.
struct ScriptedCodexServer {
    sent: Arc<Mutex<Vec<String>>>,
    outbox: VecDeque<String>,
}

impl ScriptedCodexServer {
    fn new(sent: Arc<Mutex<Vec<String>>>) -> Self {
        Self {
            sent,
            outbox: VecDeque::new(),
        }
    }

    fn respond(&mut self, frame: &str) {
        let Ok(message) = serde_json::from_str::<Value>(frame) else {
            return;
        };
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return;
        };
        // Notifications (e.g. `initialized`) carry no id and need no reply.
        let Some(id) = message.get("id").cloned() else {
            return;
        };
        match method {
            "thread/start" | "thread/resume" => {
                self.queue_result(id, json!({ "thread": { "id": "thread-golden" } }));
            }
            "turn/start" => {
                self.queue_result(id, json!({ "turn": { "id": "turn-golden" } }));
                self.outbox.push_back(
                    json!({
                        "method": "turn/completed",
                        "params": { "turn": { "status": "completed" } },
                    })
                    .to_string(),
                );
            }
            _ => self.queue_result(id, json!({})),
        }
    }

    fn queue_result(&mut self, id: Value, result: Value) {
        self.outbox
            .push_back(json!({ "id": id, "result": result }).to_string());
    }
}

#[async_trait]
impl CodexTransport for ScriptedCodexServer {
    async fn send(&mut self, frame: String) -> Result<(), CliError> {
        self.respond(&frame);
        self.sent.lock().expect("sent lock").push(frame);
        Ok(())
    }

    async fn next_frame(&mut self) -> Result<Option<String>, CliError> {
        Ok(self.outbox.pop_front())
    }

    async fn shutdown(self: Box<Self>) -> Result<(), CliError> {
        Ok(())
    }
}

#[tokio::test]
async fn golden_path_delivers_task_prompt_to_turn_start() {
    const TASK_PROMPT: &str = "GOLDEN-TASK: add a unit test for the suite parser";

    let (controller, _db, _tempdir) =
        controller_with_session_state(sample_session_state_with_codex_agent(AgentStatus::Active));

    let mut snapshot = codex_run_snapshot(CodexRunStatus::Running);
    // Force the clean "new thread" path and inject the assigned task prompt.
    snapshot.thread_id = None;
    snapshot.turn_id = None;
    snapshot.prompt = TASK_PROMPT.to_string();

    let (_control_tx, control_rx) = mpsc::unbounded_channel();
    let mut worker = CodexRunWorker::new(controller, snapshot, control_rx);

    let sent = Arc::new(Mutex::new(Vec::new()));
    let server = ScriptedCodexServer::new(Arc::clone(&sent));

    worker
        .run_with_transport(Box::new(server))
        .await
        .expect("golden swarm turn should complete");

    let frames = sent.lock().expect("sent frames");
    let turn_start = frames
        .iter()
        .find(|frame| frame.contains("\"turn/start\""))
        .expect("worker must send a turn/start frame");
    assert!(
        turn_start.contains(TASK_PROMPT),
        "the assigned task prompt must reach codex turn/start; got: {turn_start}"
    );
    assert_eq!(worker.snapshot.status, CodexRunStatus::Completed);
}
