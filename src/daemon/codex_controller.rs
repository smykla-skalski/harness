use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::{broadcast, mpsc};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::codex_transport::{CodexTransport, StdioCodexTransport};
use super::db::DaemonDb;
use super::protocol::{
    CodexApprovalDecision, CodexApprovalDecisionRequest, CodexApprovalRequest,
    CodexApprovalRequestedPayload, CodexRunListResponse, CodexRunMode, CodexRunRequest,
    CodexRunSnapshot, CodexRunStatus, CodexSteerRequest, StreamEvent,
};
use super::state;

#[derive(Clone)]
pub struct CodexControllerHandle {
    state: Arc<CodexControllerState>,
}

struct CodexControllerState {
    sender: broadcast::Sender<StreamEvent>,
    db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    active_runs: Arc<Mutex<HashMap<String, ActiveRun>>>,
}

#[derive(Clone)]
struct ActiveRun {
    control_tx: mpsc::UnboundedSender<CodexControlMessage>,
}

#[derive(Debug)]
enum CodexControlMessage {
    Approval {
        approval_id: String,
        decision: CodexApprovalDecision,
    },
    Steer {
        prompt: String,
    },
    Interrupt,
}

impl CodexControllerHandle {
    /// Create a daemon-owned Codex controller.
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    ) -> Self {
        Self {
            state: Arc::new(CodexControllerState {
                sender,
                db,
                active_runs: Arc::default(),
            }),
        }
    }

    /// Start a Codex run for a Harness session.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session cannot be resolved or the snapshot
    /// cannot be persisted.
    pub fn start_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        let prompt = request.prompt.trim();
        if prompt.is_empty() {
            return Err(CliErrorKind::workflow_parse("codex prompt cannot be empty").into());
        }

        let project_dir = self.project_dir_for_session(session_id)?;
        let now = utc_now();
        let snapshot = CodexRunSnapshot {
            run_id: format!("codex-{}", Uuid::new_v4()),
            session_id: session_id.to_string(),
            project_dir,
            thread_id: request.resume_thread_id.clone(),
            turn_id: None,
            mode: request.mode,
            status: CodexRunStatus::Queued,
            prompt: prompt.to_string(),
            latest_summary: request
                .actor
                .as_ref()
                .map(|actor| format!("Queued by {actor}")),
            final_message: None,
            error: None,
            pending_approvals: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
        };
        self.save_and_broadcast(&snapshot)?;

        let (control_tx, control_rx) = mpsc::unbounded_channel();
        self.active_runs()?
            .insert(snapshot.run_id.clone(), ActiveRun { control_tx });

        let worker = CodexRunWorker::new(self.clone(), snapshot.clone(), control_rx);
        tokio::spawn(async move {
            worker.run().await;
        });

        Ok(snapshot)
    }

    /// List Codex runs for a Harness session.
    ///
    /// # Errors
    /// Returns [`CliError`] on database failures.
    pub fn list_runs(&self, session_id: &str) -> Result<CodexRunListResponse, CliError> {
        let db = self.db()?;
        let runs = lock_db(&db)?.list_codex_runs(session_id)?;
        Ok(CodexRunListResponse { runs })
    }

    /// Load one Codex run snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on database failures or when the run is missing.
    pub fn run(&self, run_id: &str) -> Result<CodexRunSnapshot, CliError> {
        let db = self.db()?;
        lock_db(&db)?.codex_run(run_id)?.ok_or_else(|| {
            CliErrorKind::session_not_active(format!("codex run '{run_id}' not found")).into()
        })
    }

    /// Send same-turn steering text to an active Codex run.
    ///
    /// # Errors
    /// Returns [`CliError`] when the run is inactive or the request cannot be queued.
    pub fn steer(
        &self,
        run_id: &str,
        request: &CodexSteerRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        let prompt = request.prompt.trim();
        if prompt.is_empty() {
            return Err(CliErrorKind::workflow_parse("codex steer prompt cannot be empty").into());
        }
        let active = self.active_run(run_id)?;
        active
            .control_tx
            .send(CodexControlMessage::Steer {
                prompt: prompt.to_string(),
            })
            .map_err(|error| CliErrorKind::workflow_io(format!("queue codex steer: {error}")))?;
        self.run(run_id)
    }

    /// Interrupt an active Codex turn.
    ///
    /// # Errors
    /// Returns [`CliError`] when the run is inactive or the request cannot be queued.
    pub fn interrupt(&self, run_id: &str) -> Result<CodexRunSnapshot, CliError> {
        let active = self.active_run(run_id)?;
        active
            .control_tx
            .send(CodexControlMessage::Interrupt)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("queue codex interrupt: {error}"))
            })?;
        self.run(run_id)
    }

    /// Resolve a pending Codex approval prompt.
    ///
    /// # Errors
    /// Returns [`CliError`] when the run is inactive or the approval cannot be queued.
    pub fn resolve_approval(
        &self,
        run_id: &str,
        approval_id: &str,
        request: &CodexApprovalDecisionRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        let active = self.active_run(run_id)?;
        active
            .control_tx
            .send(CodexControlMessage::Approval {
                approval_id: approval_id.to_string(),
                decision: request.decision,
            })
            .map_err(|error| CliErrorKind::workflow_io(format!("queue codex approval: {error}")))?;
        self.run(run_id)
    }

    fn active_run(&self, run_id: &str) -> Result<ActiveRun, CliError> {
        self.active_runs()?.get(run_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!("codex run '{run_id}' is not active")).into()
        })
    }

    fn project_dir_for_session(&self, session_id: &str) -> Result<String, CliError> {
        let db = self.db()?;
        let guard = lock_db(&db)?;
        if let Some(project_dir) = guard.project_dir_for_session(session_id)? {
            return Ok(project_dir);
        }
        drop(guard);

        let resolved = super::index::resolve_session(session_id)?;
        let fallback = resolved
            .project
            .project_dir
            .or(resolved.project.repository_root)
            .unwrap_or(resolved.project.context_root);
        Ok(fallback.display().to_string())
    }

    fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        self.state
            .db
            .get()
            .cloned()
            .ok_or_else(|| CliErrorKind::workflow_io("daemon database is not ready").into())
    }

    fn active_runs(&self) -> Result<MutexGuard<'_, HashMap<String, ActiveRun>>, CliError> {
        self.state.active_runs.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("codex active run lock poisoned: {error}")).into()
        })
    }

    fn remove_active_run(&self, run_id: &str) {
        let Ok(mut active_runs) = self.state.active_runs.lock() else {
            return;
        };
        active_runs.remove(run_id);
    }

    fn save_and_broadcast(&self, snapshot: &CodexRunSnapshot) -> Result<(), CliError> {
        let db = self.db()?;
        lock_db(&db)?.save_codex_run(snapshot)?;
        self.broadcast("codex_run_updated", snapshot, snapshot);
        Ok(())
    }

    fn broadcast_approval(&self, snapshot: &CodexRunSnapshot, approval: &CodexApprovalRequest) {
        let payload = CodexApprovalRequestedPayload {
            run: snapshot.clone(),
            approval: approval.clone(),
        };
        self.broadcast("codex_approval_requested", snapshot, &payload);
    }

    fn broadcast<T: Serialize>(&self, event: &str, snapshot: &CodexRunSnapshot, payload: &T) {
        let Some(payload) = codex_event_payload(event, payload) else {
            return;
        };
        let event = StreamEvent {
            event: event.to_string(),
            recorded_at: utc_now(),
            session_id: Some(snapshot.session_id.clone()),
            payload,
        };
        let _ = self.state.sender.send(event);
    }
}

fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn codex_event_payload<T: Serialize>(event: &str, payload: &T) -> Option<Value> {
    match serde_json::to_value(payload) {
        Ok(payload) => Some(payload),
        Err(error) => {
            tracing::warn!(%error, event, "failed to serialize codex controller event");
            None
        }
    }
}

struct CodexRunWorker {
    controller: CodexControllerHandle,
    snapshot: CodexRunSnapshot,
    control_rx: mpsc::UnboundedReceiver<CodexControlMessage>,
    pending_approvals: HashMap<String, PendingApproval>,
    agent_message_delta: String,
}

struct PendingApproval {
    request_id: Value,
    method: String,
}

impl CodexRunWorker {
    fn new(
        controller: CodexControllerHandle,
        snapshot: CodexRunSnapshot,
        control_rx: mpsc::UnboundedReceiver<CodexControlMessage>,
    ) -> Self {
        Self {
            controller,
            snapshot,
            control_rx,
            pending_approvals: HashMap::new(),
            agent_message_delta: String::new(),
        }
    }

    async fn run(mut self) {
        let result = self.run_inner().await;
        if let Err(error) = result {
            let message = error.to_string();
            self.fail(&message);
        }
        self.controller.remove_active_run(&self.snapshot.run_id);
    }

    async fn run_inner(&mut self) -> Result<(), CliError> {
        self.transition(
            CodexRunStatus::Running,
            Some("Starting codex app-server"),
            None,
        )?;
        let transport: Box<dyn CodexTransport> = Box::new(StdioCodexTransport::spawn()?);
        let mut rpc = CodexJsonRpc::new(transport);
        self.initialize(&mut rpc).await?;
        self.start_or_resume_thread(&mut rpc).await?;
        self.start_turn(&mut rpc).await?;
        self.event_loop(&mut rpc).await
    }

    async fn initialize(&self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let params = json!({
            "clientInfo": {
                "name": "harness-daemon",
                "title": "Harness daemon",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {
                "experimentalApi": true
            }
        });
        let _ = rpc.request("initialize", params).await?;
        Ok(())
    }

    async fn start_or_resume_thread(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let method = if self.snapshot.thread_id.is_some() {
            "thread/resume"
        } else {
            "thread/start"
        };
        let mut params = json!({
            "cwd": self.snapshot.project_dir,
            "sandbox": thread_sandbox(self.snapshot.mode),
            "approvalPolicy": approval_policy(self.snapshot.mode),
            "approvalsReviewer": "user",
            "persistExtendedHistory": true,
            "developerInstructions": mode_instructions(self.snapshot.mode),
        });
        if let Some(thread_id) = &self.snapshot.thread_id {
            params["threadId"] = json!(thread_id);
        }

        let result = rpc.request(method, params).await?;
        let thread_id = result
            .pointer("/thread/id")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                CliErrorKind::workflow_parse("codex thread response missing thread.id")
            })?;
        self.snapshot.thread_id = Some(thread_id.to_string());
        self.snapshot.latest_summary = Some(format!("Thread {thread_id} ready"));
        self.touch_and_save()?;
        Ok(())
    }

    async fn start_turn(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let thread_id = self.thread_id()?;
        let result = rpc
            .request(
                "turn/start",
                json!({
                    "threadId": thread_id,
                    "cwd": self.snapshot.project_dir,
                    "input": [{"type": "text", "text": self.snapshot.prompt}],
                    "approvalPolicy": approval_policy(self.snapshot.mode),
                    "approvalsReviewer": "user",
                    "sandboxPolicy": turn_sandbox_policy(self.snapshot.mode, &self.snapshot.project_dir),
                }),
            )
            .await?;
        let turn_id = result
            .pointer("/turn/id")
            .and_then(Value::as_str)
            .ok_or_else(|| CliErrorKind::workflow_parse("codex turn response missing turn.id"))?;
        self.snapshot.turn_id = Some(turn_id.to_string());
        self.snapshot.latest_summary = Some(format!("Turn {turn_id} started"));
        self.touch_and_save()?;
        Ok(())
    }

    async fn event_loop(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        loop {
            tokio::select! {
                maybe_line = rpc.next_message() => {
                    let Some(message) = maybe_line? else {
                        return Err(CliErrorKind::workflow_io("codex app-server exited before turn completion").into());
                    };
                    if self.handle_rpc_message(&message)? {
                        return Ok(());
                    }
                }
                maybe_control = self.control_rx.recv() => {
                    let Some(control) = maybe_control else {
                        continue;
                    };
                    self.handle_control(rpc, control).await?;
                }
            }
        }
    }

    fn handle_rpc_message(&mut self, message: &Value) -> Result<bool, CliError> {
        if message.get("error").is_some() {
            let error = message
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("codex app-server request failed");
            return Err(CliErrorKind::workflow_io(error.to_string()).into());
        }

        if let Some(method) = message.get("method").and_then(Value::as_str) {
            if message.get("id").is_some() {
                self.handle_server_request(message, method)?;
                return Ok(false);
            }
            return self.handle_notification(method, message.get("params").unwrap_or(&Value::Null));
        }

        Ok(false)
    }

    fn handle_notification(&mut self, method: &str, params: &Value) -> Result<bool, CliError> {
        match method {
            "turn/started" => {
                if let Some(turn_id) = params.pointer("/turn/id").and_then(Value::as_str) {
                    self.snapshot.turn_id = Some(turn_id.to_string());
                    self.snapshot.latest_summary = Some(format!("Turn {turn_id} is running"));
                    self.touch_and_save()?;
                }
                Ok(false)
            }
            "item/agentMessage/delta" => {
                if let Some(delta) = params.get("delta").and_then(Value::as_str) {
                    self.agent_message_delta.push_str(delta);
                    self.snapshot.latest_summary = Some(trim_summary(&self.agent_message_delta));
                    self.touch_and_save()?;
                }
                Ok(false)
            }
            "item/completed" => {
                self.handle_item_completed(params)?;
                Ok(false)
            }
            "turn/completed" => {
                self.handle_turn_completed(params)?;
                Ok(true)
            }
            "error" => {
                let message = params
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("codex app-server reported an error");
                self.fail(message);
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    fn handle_item_completed(&mut self, params: &Value) -> Result<(), CliError> {
        let Some(item) = params.get("item") else {
            return Ok(());
        };
        if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
            return Ok(());
        }
        let Some(text) = item.get("text").and_then(Value::as_str) else {
            return Ok(());
        };
        self.snapshot.latest_summary = Some(trim_summary(text));
        if item.get("phase").and_then(Value::as_str) == Some("final_answer") {
            self.snapshot.final_message = Some(text.to_string());
        }
        self.touch_and_save()
    }

    fn handle_turn_completed(&mut self, params: &Value) -> Result<(), CliError> {
        let status = params
            .pointer("/turn/status")
            .and_then(Value::as_str)
            .unwrap_or("completed");
        match status {
            "completed" => {
                if self.snapshot.final_message.is_none() && !self.agent_message_delta.is_empty() {
                    self.snapshot.final_message = Some(self.agent_message_delta.clone());
                }
                self.transition(
                    CodexRunStatus::Completed,
                    Some("Codex turn completed"),
                    None,
                )
            }
            "interrupted" => self.transition(
                CodexRunStatus::Cancelled,
                Some("Codex turn interrupted"),
                None,
            ),
            "failed" => {
                let message = params
                    .pointer("/turn/error/message")
                    .and_then(Value::as_str)
                    .unwrap_or("codex turn failed")
                    .to_string();
                let summary = message.clone();
                self.transition(
                    CodexRunStatus::Failed,
                    Some(summary.as_str()),
                    Some(message),
                )
            }
            _ => self.transition(CodexRunStatus::Completed, Some("Codex turn finished"), None),
        }
    }

    fn handle_server_request(&mut self, message: &Value, method: &str) -> Result<(), CliError> {
        let request_id = message
            .get("id")
            .cloned()
            .ok_or_else(|| CliErrorKind::workflow_parse("codex approval request missing id"))?;
        let params = message.get("params").unwrap_or(&Value::Null);
        let Some(approval) = approval_from_request(method, value_id_string(&request_id), params)
        else {
            tracing::warn!(method, "received unsupported codex server request");
            return Ok(());
        };

        self.pending_approvals.insert(
            approval.approval_id.clone(),
            PendingApproval {
                request_id,
                method: method.to_string(),
            },
        );
        self.snapshot.pending_approvals.push(approval.clone());
        self.transition(
            CodexRunStatus::WaitingApproval,
            Some(approval.title.as_str()),
            None,
        )?;
        self.controller
            .broadcast_approval(&self.snapshot, &approval);
        Ok(())
    }

    async fn handle_control(
        &mut self,
        rpc: &mut CodexJsonRpc,
        control: CodexControlMessage,
    ) -> Result<(), CliError> {
        match control {
            CodexControlMessage::Approval {
                approval_id,
                decision,
            } => self.resolve_approval(rpc, &approval_id, decision).await,
            CodexControlMessage::Steer { prompt } => self.steer(rpc, &prompt).await,
            CodexControlMessage::Interrupt => self.interrupt(rpc).await,
        }
    }

    async fn resolve_approval(
        &mut self,
        rpc: &mut CodexJsonRpc,
        approval_id: &str,
        decision: CodexApprovalDecision,
    ) -> Result<(), CliError> {
        let Some(pending) = self.pending_approvals.remove(approval_id) else {
            return Err(CliErrorKind::session_not_active(format!(
                "codex approval '{approval_id}' is not pending"
            ))
            .into());
        };
        let result = approval_result(&pending.method, decision);
        rpc.send_response(pending.request_id, result).await?;
        self.snapshot
            .pending_approvals
            .retain(|approval| approval.approval_id != approval_id);
        self.snapshot.status = CodexRunStatus::Running;
        self.snapshot.latest_summary = Some(format!("Approval {approval_id} resolved"));
        self.touch_and_save()
    }

    async fn steer(&mut self, rpc: &mut CodexJsonRpc, prompt: &str) -> Result<(), CliError> {
        let thread_id = self.thread_id()?;
        let turn_id = self.turn_id()?;
        let _ = rpc
            .send_request(
                "turn/steer",
                json!({
                    "threadId": thread_id,
                    "expectedTurnId": turn_id,
                    "input": [{"type": "text", "text": prompt}],
                }),
            )
            .await?;
        self.snapshot.latest_summary = Some("Steering prompt sent".to_string());
        self.touch_and_save()
    }

    async fn interrupt(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let thread_id = self.thread_id()?;
        let turn_id = self.turn_id()?;
        let _ = rpc
            .send_request(
                "turn/interrupt",
                json!({
                    "threadId": thread_id,
                    "turnId": turn_id,
                }),
            )
            .await?;
        self.snapshot.latest_summary = Some("Interrupt requested".to_string());
        self.touch_and_save()
    }

    fn thread_id(&self) -> Result<String, CliError> {
        self.snapshot
            .thread_id
            .clone()
            .ok_or_else(|| CliErrorKind::workflow_io("codex thread id is not ready").into())
    }

    fn turn_id(&self) -> Result<String, CliError> {
        self.snapshot
            .turn_id
            .clone()
            .ok_or_else(|| CliErrorKind::workflow_io("codex turn id is not ready").into())
    }

    fn transition(
        &mut self,
        status: CodexRunStatus,
        latest_summary: Option<&str>,
        error: Option<String>,
    ) -> Result<(), CliError> {
        self.snapshot.status = status;
        if let Some(summary) = latest_summary {
            self.snapshot.latest_summary = Some(summary.to_string());
        }
        self.snapshot.error = error;
        self.touch_and_save()
    }

    fn fail(&mut self, message: &str) {
        self.mark_failed(message);
        self.persist_failure(message);
    }

    fn mark_failed(&mut self, message: &str) {
        let message = message.to_string();
        self.snapshot.status = CodexRunStatus::Failed;
        self.snapshot.latest_summary = Some(message.clone());
        self.snapshot.error = Some(message);
        self.snapshot.updated_at = utc_now();
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion; tokio-rs/tracing#553"
    )]
    fn persist_failure(&self, message: &str) {
        if let Err(error) = self.controller.save_and_broadcast(&self.snapshot) {
            tracing::warn!(%error, "failed to persist codex failure");
        }
        let _ = state::append_event("warn", &format!("codex run failed: {message}"));
    }

    fn touch_and_save(&mut self) -> Result<(), CliError> {
        self.snapshot.updated_at = utc_now();
        self.controller.save_and_broadcast(&self.snapshot)
    }
}

struct CodexJsonRpc {
    transport: Box<dyn CodexTransport>,
    pending_messages: VecDeque<Value>,
    next_id: i64,
}

impl CodexJsonRpc {
    fn new(transport: Box<dyn CodexTransport>) -> Self {
        Self {
            transport,
            pending_messages: VecDeque::new(),
            next_id: 1,
        }
    }

    async fn request(&mut self, method: &str, params: Value) -> Result<Value, CliError> {
        let id = self.send_request(method, params).await?;
        loop {
            let Some(message) = self.read_stdout_message().await? else {
                return Err(
                    CliErrorKind::workflow_io("codex app-server exited during request").into(),
                );
            };
            if message.get("id") != Some(&id) {
                self.pending_messages.push_back(message);
                continue;
            }
            if let Some(error) = message.get("error") {
                let message = error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("codex app-server request failed");
                return Err(CliErrorKind::workflow_io(message.to_string()).into());
            }
            return Ok(message.get("result").cloned().unwrap_or(Value::Null));
        }
    }

    async fn send_request(&mut self, method: &str, params: Value) -> Result<Value, CliError> {
        let id = Value::from(self.next_id);
        self.next_id += 1;
        self.send(json!({
            "id": id,
            "method": method,
            "params": params,
        }))
        .await?;
        Ok(id)
    }

    async fn send_response(&mut self, request_id: Value, result: Value) -> Result<(), CliError> {
        self.send(json!({
            "id": request_id,
            "result": result,
        }))
        .await
    }

    async fn send(&mut self, message: Value) -> Result<(), CliError> {
        let encoded = serde_json::to_string(&message).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("codex rpc request: {error}"))
        })?;
        self.transport.send(encoded).await
    }

    async fn next_message(&mut self) -> Result<Option<Value>, CliError> {
        if let Some(message) = self.pending_messages.pop_front() {
            return Ok(Some(message));
        }
        self.read_stdout_message().await
    }

    async fn read_stdout_message(&mut self) -> Result<Option<Value>, CliError> {
        let Some(line) = self.transport.next_frame().await? else {
            return Ok(None);
        };
        serde_json::from_str(&line).map(Some).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse codex app-server JSON: {error}")).into()
        })
    }
}

fn thread_sandbox(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report => "read-only",
        CodexRunMode::WorkspaceWrite | CodexRunMode::Approval => "workspace-write",
    }
}

fn approval_policy(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Approval => "on-request",
        CodexRunMode::Report | CodexRunMode::WorkspaceWrite => "never",
    }
}

fn turn_sandbox_policy(mode: CodexRunMode, project_dir: &str) -> Value {
    match mode {
        CodexRunMode::Report => json!({
            "type": "readOnly",
            "networkAccess": false,
            "access": { "type": "fullAccess" }
        }),
        CodexRunMode::WorkspaceWrite | CodexRunMode::Approval => json!({
            "type": "workspaceWrite",
            "networkAccess": false,
            "writableRoots": [project_dir],
            "readOnlyAccess": { "type": "fullAccess" }
        }),
    }
}

fn mode_instructions(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report => {
            "You are running inside Harness report mode. Inspect the workspace and answer the user, but do not edit files, run mutating commands, or request approvals."
        }
        CodexRunMode::WorkspaceWrite => {
            "You are running inside Harness workspace-write mode. Keep changes scoped to the selected Harness project directory and do not request approvals."
        }
        CodexRunMode::Approval => {
            "You are running inside Harness approval mode. Request approval before commands or file changes that require it and wait for the Harness macOS app decision."
        }
    }
}

fn approval_from_request(
    method: &str,
    request_id: String,
    params: &Value,
) -> Option<CodexApprovalRequest> {
    match method {
        "item/commandExecution/requestApproval" => {
            Some(command_approval_from_request(request_id, params))
        }
        "item/fileChange/requestApproval" => Some(file_approval_from_request(request_id, params)),
        "item/permissions/requestApproval" => {
            Some(permission_approval_from_request(request_id, params))
        }
        _ => None,
    }
}

struct ApprovalTemplate<'a> {
    kind: &'a str,
    title: &'a str,
    default_detail: &'a str,
    cwd: Option<String>,
    command: Option<String>,
    file_path: Option<String>,
}

fn command_approval_from_request(request_id: String, params: &Value) -> CodexApprovalRequest {
    let approval_id = params
        .get("approvalId")
        .and_then(Value::as_str)
        .or_else(|| params.get("itemId").and_then(Value::as_str))
        .unwrap_or(request_id.as_str())
        .to_string();
    approval_request(
        request_id,
        approval_id,
        params,
        ApprovalTemplate {
            kind: "command",
            title: "Command approval requested",
            default_detail: "Codex wants to run a command.",
            cwd: string_param(params, "cwd"),
            command: string_param(params, "command"),
            file_path: None,
        },
    )
}

fn file_approval_from_request(request_id: String, params: &Value) -> CodexApprovalRequest {
    let approval_id = item_or_request_id(params, &request_id);
    approval_request(
        request_id,
        approval_id,
        params,
        ApprovalTemplate {
            kind: "file_change",
            title: "File change approval requested",
            default_detail: "Codex wants to change files.",
            cwd: None,
            command: None,
            file_path: string_param(params, "grantRoot"),
        },
    )
}

fn permission_approval_from_request(request_id: String, params: &Value) -> CodexApprovalRequest {
    let approval_id = item_or_request_id(params, &request_id);
    approval_request(
        request_id,
        approval_id,
        params,
        ApprovalTemplate {
            kind: "permissions",
            title: "Permission approval requested",
            default_detail: "Codex wants additional permissions.",
            cwd: None,
            command: None,
            file_path: None,
        },
    )
}

fn approval_request(
    request_id: String,
    approval_id: String,
    params: &Value,
    template: ApprovalTemplate<'_>,
) -> CodexApprovalRequest {
    CodexApprovalRequest {
        approval_id,
        request_id,
        kind: template.kind.to_string(),
        title: template.title.to_string(),
        detail: params
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or(template.default_detail)
            .to_string(),
        thread_id: string_param(params, "threadId"),
        turn_id: string_param(params, "turnId"),
        item_id: string_param(params, "itemId"),
        cwd: template.cwd,
        command: template.command,
        file_path: template.file_path,
    }
}

fn item_or_request_id(params: &Value, request_id: &str) -> String {
    params
        .get("itemId")
        .and_then(Value::as_str)
        .unwrap_or(request_id)
        .to_string()
}

fn string_param(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn approval_result(method: &str, decision: CodexApprovalDecision) -> Value {
    match method {
        "item/permissions/requestApproval" => {
            let scope = if decision == CodexApprovalDecision::AcceptForSession {
                "session"
            } else {
                "turn"
            };
            json!({
                "permissions": {
                    "fileSystem": null,
                    "network": null
                },
                "scope": scope,
            })
        }
        _ => json!({
            "decision": app_server_approval_decision(decision),
        }),
    }
}

fn app_server_approval_decision(decision: CodexApprovalDecision) -> &'static str {
    match decision {
        CodexApprovalDecision::Accept => "accept",
        CodexApprovalDecision::AcceptForSession => "acceptForSession",
        CodexApprovalDecision::Decline => "decline",
        CodexApprovalDecision::Cancel => "cancel",
    }
}

fn value_id_string(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Number(value) => value.to_string(),
        _ => value.to_string(),
    }
}

fn trim_summary(value: &str) -> String {
    const LIMIT: usize = 512;
    let trimmed = value.trim();
    if trimmed.len() <= LIMIT {
        return trimmed.to_string();
    }
    trimmed
        .char_indices()
        .take_while(|(index, _)| *index < LIMIT)
        .map(|(_, ch)| ch)
        .collect()
}
