//! Golden-path regression net for the Codex app-server swarm substrate.
//!
//! These tests drive the real `CodexRunWorker` through `run_with_transport`
//! against a scripted, in-process Codex `app-server` (no `codex` binary, no
//! Mac, no network), pinning the substrate's turn lifecycle: an assigned task
//! prompt reaches `turn/start`, completions/failures land in the snapshot, the
//! agent's final message is captured, and an existing thread resumes. This is
//! the M0 golden-path harness described in `docs/FOCUS.md`; later slices extend
//! it toward the M2/M3/M4 dispatch, review, and land stages.
//!
//! All tests characterize *current* behavior and are expected to pass; they are
//! the regression floor the M2 fixes build on, not the (still-failing) M2 spec
//! assertions.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::super::active_runs::CodexControlMessage;
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
/// reply. After it answers `turn/start` it enqueues a configurable list of
/// trailing notifications (deltas, item completions, the terminal
/// `turn/completed`) so the worker's event loop runs deterministically to a
/// known end state with no real concurrency.
struct ScriptedCodexServer {
    sent: Arc<Mutex<Vec<String>>>,
    outbox: VecDeque<String>,
    after_turn_start: Vec<String>,
}

impl ScriptedCodexServer {
    /// Default server: a clean turn that completes successfully.
    fn new(sent: Arc<Mutex<Vec<String>>>) -> Self {
        Self::with_turn_events(sent, vec![turn_completed_frame("completed", None)])
    }

    /// Server whose post-`turn/start` notifications are scripted by the caller.
    fn with_turn_events(sent: Arc<Mutex<Vec<String>>>, after_turn_start: Vec<String>) -> Self {
        Self {
            sent,
            outbox: VecDeque::new(),
            after_turn_start,
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
                let events = std::mem::take(&mut self.after_turn_start);
                self.outbox.extend(events);
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

fn turn_completed_frame(status: &str, error: Option<&str>) -> String {
    let mut turn = json!({ "status": status });
    if let Some(message) = error {
        turn["error"] = json!({ "message": message });
    }
    json!({ "method": "turn/completed", "params": { "turn": turn } }).to_string()
}

fn agent_delta_frame(delta: &str) -> String {
    json!({ "method": "item/agentMessage/delta", "params": { "delta": delta } }).to_string()
}

fn final_message_frame(text: &str) -> String {
    json!({
        "method": "item/completed",
        "params": { "item": { "type": "agentMessage", "text": text, "phase": "final_answer" } },
    })
    .to_string()
}

/// Build a worker over a real (temp-DB) controller with a registered Codex
/// agent. Returns the control sender and the `db`/`tempdir` guards; callers must
/// keep all three alive for the duration of the run (the sender keeps the
/// worker's control channel open so `recv()` pends rather than returning `None`,
/// and the tempdir backs the DB).
#[allow(clippy::type_complexity)]
fn worker_with_prompt(
    prompt: &str,
    thread_id: Option<&str>,
) -> (
    CodexRunWorker,
    mpsc::UnboundedSender<CodexControlMessage>,
    Arc<Mutex<crate::daemon::db::DaemonDb>>,
    tempfile::TempDir,
) {
    let (controller, db, tempdir) =
        controller_with_session_state(sample_session_state_with_codex_agent(AgentStatus::Active));

    let mut snapshot = codex_run_snapshot(CodexRunStatus::Running);
    snapshot.thread_id = thread_id.map(str::to_string);
    snapshot.turn_id = None;
    snapshot.prompt = prompt.to_string();

    let (control_tx, control_rx) = mpsc::unbounded_channel();
    let worker = CodexRunWorker::new(controller, snapshot, control_rx);
    (worker, control_tx, db, tempdir)
}

#[tokio::test]
async fn golden_path_delivers_task_prompt_to_turn_start() {
    const TASK_PROMPT: &str = "GOLDEN-TASK: add a unit test for the suite parser";

    let (mut worker, _control_tx, _db, _tempdir) = worker_with_prompt(TASK_PROMPT, None);
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

#[tokio::test]
async fn failed_turn_lands_failed_status_and_surfaces_error() {
    const ERROR: &str = "model refused: sandbox write denied";

    let (mut worker, _control_tx, _db, _tempdir) = worker_with_prompt("do the thing", None);
    let sent = Arc::new(Mutex::new(Vec::new()));
    let server = ScriptedCodexServer::with_turn_events(
        Arc::clone(&sent),
        vec![turn_completed_frame("failed", Some(ERROR))],
    );

    worker
        .run_with_transport(Box::new(server))
        .await
        .expect("the run loop completes even when the turn fails");

    assert_eq!(worker.snapshot.status, CodexRunStatus::Failed);
    assert_eq!(worker.snapshot.error.as_deref(), Some(ERROR));
}

#[tokio::test]
async fn agent_final_message_is_captured_from_item_completed() {
    const FINAL: &str = "Added the test and it passes.";

    let (mut worker, _control_tx, _db, _tempdir) = worker_with_prompt("write a test", None);
    let sent = Arc::new(Mutex::new(Vec::new()));
    let server = ScriptedCodexServer::with_turn_events(
        Arc::clone(&sent),
        vec![
            agent_delta_frame("Added the test "),
            agent_delta_frame("and it passes."),
            final_message_frame(FINAL),
            turn_completed_frame("completed", None),
        ],
    );

    worker
        .run_with_transport(Box::new(server))
        .await
        .expect("turn with agent output should complete");

    assert_eq!(worker.snapshot.status, CodexRunStatus::Completed);
    assert_eq!(worker.snapshot.final_message.as_deref(), Some(FINAL));
}

#[tokio::test]
async fn existing_thread_resumes_instead_of_starting() {
    let (mut worker, _control_tx, _db, _tempdir) = worker_with_prompt("continue the work", Some("thread-prior"));
    let sent = Arc::new(Mutex::new(Vec::new()));
    let server = ScriptedCodexServer::new(Arc::clone(&sent));

    worker
        .run_with_transport(Box::new(server))
        .await
        .expect("resumed turn should complete");

    let frames = sent.lock().expect("sent frames");
    assert!(
        frames.iter().any(|frame| frame.contains("\"thread/resume\"")),
        "a worker with an existing thread must resume it, not start a new thread"
    );
    assert!(
        frames.iter().all(|frame| !frame.contains("\"thread/start\"")),
        "resume path must not also send thread/start"
    );
    assert_eq!(worker.snapshot.status, CodexRunStatus::Completed);
}
