use std::collections::HashMap;

use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::daemon::protocol::{CodexApprovalDecision, CodexRunSnapshot, CodexRunStatus};
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::approvals::{
    approval_from_request, approval_policy, approval_result, mode_instructions, thread_sandbox,
    trim_summary, turn_sandbox_policy,
};
use super::handle::{CodexControlMessage, CodexControllerHandle};
use super::rpc::CodexJsonRpc;

pub(super) struct CodexRunWorker {
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
    pub(super) fn new(
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

    pub(super) async fn run(mut self) {
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
        let transport = self.controller.current_transport_kind().connect().await?;
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
        if let Some(model) = &self.snapshot.model {
            params["model"] = json!(model);
        }
        if let Some(effort) = &self.snapshot.effort {
            params["reasoning"] = json!({ "effort": effort });
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
        tracing::error!(
            session_id = %self.snapshot.session_id,
            run_id = %self.snapshot.run_id,
            error_message = message,
            "codex run failed"
        );
        state::append_event_best_effort(
            "warn",
            &format!(
                "codex run failed for session {} run {}: {message}",
                self.snapshot.session_id, self.snapshot.run_id
            ),
        );
    }

    fn touch_and_save(&mut self) -> Result<(), CliError> {
        self.snapshot.updated_at = utc_now();
        self.controller.save_and_broadcast(&self.snapshot)
    }
}

fn value_id_string(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Number(value) => value.to_string(),
        _ => value.to_string(),
    }
}
