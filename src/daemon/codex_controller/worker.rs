use std::collections::HashMap;
use std::time::Instant;

use serde_json::Value;
use tokio::sync::mpsc;

use crate::daemon::codex_transport::CodexTransport;
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use crate::errors::{CliError, CliErrorKind};

use super::active_runs::CodexControlMessage;
use super::approvals::{
    approval_from_request, approval_policy, mode_instructions, permission_profile,
    runtime_workspace_roots, trim_summary, upsert_pending_approval, workspace_permission_config,
};
use super::handle::CodexControllerHandle;
use super::rpc::CodexJsonRpc;
use super::wire::{self, AppServerNotification};
use super::worker_startup::startup_request;

#[cfg(test)]
pub(super) use super::worker_startup::{STARTUP_REQUEST_TIMEOUT, with_startup_timeout};

pub(super) struct CodexRunWorker {
    pub(super) controller: CodexControllerHandle,
    pub(super) snapshot: CodexRunSnapshot,
    pub(super) control_rx: mpsc::UnboundedReceiver<CodexControlMessage>,
    pub(super) pending_approvals: HashMap<String, Vec<PendingApproval>>,
    pub(super) agent_message_delta: String,
    pub(super) last_delta_persist_at: Option<Instant>,
}

pub(super) struct PendingApproval {
    pub(super) request_id: Value,
    pub(super) method: String,
    pub(super) params: Value,
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
            last_delta_persist_at: None,
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
        self.run_with_transport(transport).await
    }

    async fn run_with_transport(
        &mut self,
        transport: Box<dyn CodexTransport>,
    ) -> Result<(), CliError> {
        let mut rpc = CodexJsonRpc::new(transport);
        let result = async {
            self.initialize(&mut rpc).await?;
            self.start_or_resume_thread(&mut rpc).await?;
            self.start_turn(&mut rpc).await?;
            self.event_loop(&mut rpc).await
        }
        .await;
        let shutdown_result = rpc.shutdown().await;
        result?;
        shutdown_result
    }

    async fn initialize(&self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let params = wire::initialize_params(env!("CARGO_PKG_VERSION"))?;
        let _ = startup_request(rpc, wire::METHOD_INITIALIZE, params, "initialize").await?;
        rpc.send_notification(wire::METHOD_INITIALIZED, None)
            .await?;
        Ok(())
    }

    async fn start_or_resume_thread(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let method = if self.snapshot.thread_id.is_some() {
            wire::METHOD_THREAD_RESUME
        } else {
            wire::METHOD_THREAD_START
        };
        let runtime_workspace_roots = runtime_workspace_roots(&self.snapshot.project_dir);
        let uses_workspace_profile = self.snapshot.mode == CodexRunMode::WorkspaceWrite;
        let permission_config = uses_workspace_profile
            .then(|| workspace_permission_config(&self.snapshot.project_dir));
        let params = wire::thread_params(wire::ThreadParamsInput {
            cwd: &self.snapshot.project_dir,
            runtime_workspace_roots: &runtime_workspace_roots,
            permissions: permission_profile(self.snapshot.mode),
            config: permission_config.as_ref(),
            approval_policy: approval_policy(self.snapshot.mode),
            developer_instructions: mode_instructions(self.snapshot.mode),
            thread_id: self.snapshot.thread_id.as_deref(),
            model: self.snapshot.model.as_deref(),
        })?;

        let result = startup_request(rpc, method, params, method).await?;
        let thread_id = wire::thread_id_from_result(&result).ok_or_else(|| {
            CliErrorKind::workflow_parse("codex thread response missing thread.id")
        })?;
        self.snapshot.thread_id = Some(thread_id.clone());
        self.snapshot.latest_summary = Some(format!("Thread {thread_id} ready"));
        self.record_event(method, format!("Codex thread {thread_id} ready"), &result);
        self.touch_and_save()?;
        Ok(())
    }

    async fn start_turn(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let thread_id = self.thread_id()?;
        let runtime_workspace_roots = runtime_workspace_roots(&self.snapshot.project_dir);
        let params = wire::turn_start_params(
            &thread_id,
            &self.snapshot.project_dir,
            &runtime_workspace_roots,
            &self.snapshot.prompt,
            approval_policy(self.snapshot.mode),
            self.snapshot.model.as_deref(),
            self.snapshot.effort.as_deref(),
        )?;
        let result = startup_request(rpc, wire::METHOD_TURN_START, params, "turn/start").await?;
        let turn_id = wire::turn_id_from_result(&result)
            .ok_or_else(|| CliErrorKind::workflow_parse("codex turn response missing turn.id"))?;
        self.snapshot.turn_id = Some(turn_id.clone());
        self.snapshot.latest_summary = Some(format!("Turn {turn_id} started"));
        self.record_event(
            wire::METHOD_TURN_START,
            format!("Codex turn {turn_id} started"),
            &result,
        );
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
                    if self.handle_rpc_message(rpc, &message).await? {
                        return Ok(());
                    }
                }
                maybe_control = self.control_rx.recv() => {
                    let Some(control) = maybe_control else {
                        continue;
                    };
                    if self.handle_control(rpc, control).await? {
                        return Ok(());
                    }
                }
            }
        }
    }

    async fn handle_rpc_message(
        &mut self,
        rpc: &mut CodexJsonRpc,
        message: &Value,
    ) -> Result<bool, CliError> {
        if message.get("error").is_some() {
            let error = message
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("codex app-server request failed");
            return Err(CliErrorKind::workflow_io(error.to_string()).into());
        }

        if let Some(method) = message.get("method").and_then(Value::as_str) {
            if message.get("id").is_some() {
                self.handle_server_request(rpc, message, method).await?;
                return Ok(false);
            }
            return self.handle_notification(method, message.get("params").unwrap_or(&Value::Null));
        }

        Ok(false)
    }

    fn handle_notification(&mut self, method: &str, params: &Value) -> Result<bool, CliError> {
        if !self.notification_matches_active_turn(params) {
            return Ok(false);
        }
        let notification = wire::parse_notification(method, params);
        match notification {
            AppServerNotification::TurnStarted { turn_id } => {
                self.record_event(method, wire::notification_summary(method, params), params);
                if let Some(turn_id) = turn_id {
                    self.snapshot.turn_id = Some(turn_id.clone());
                    self.snapshot.latest_summary = Some(format!("Turn {turn_id} is running"));
                    self.touch_and_save()?;
                }
                Ok(false)
            }
            AppServerNotification::AgentMessageDelta { delta } => {
                if let Some(delta) = delta {
                    self.agent_message_delta.push_str(&delta);
                    self.snapshot.latest_summary = Some(trim_summary(&self.agent_message_delta));
                    if self.should_persist_delta_update() {
                        self.touch_and_save()?;
                    }
                }
                Ok(false)
            }
            AppServerNotification::ItemCompleted { item } => {
                self.record_event(method, wire::notification_summary(method, params), params);
                self.handle_item_completed(&item)?;
                Ok(false)
            }
            AppServerNotification::TurnCompleted {
                status,
                error_message,
            } => {
                self.record_event(method, wire::notification_summary(method, params), params);
                self.handle_turn_completed(status.as_deref(), error_message)?;
                Ok(true)
            }
            AppServerNotification::Error { message } => {
                self.record_event(method, wire::notification_summary(method, params), params);
                let message = message
                    .as_deref()
                    .unwrap_or("codex app-server reported an error");
                self.fail(message);
                Ok(true)
            }
            AppServerNotification::Other => {
                self.record_event(method, wire::notification_summary(method, params), params);
                self.touch_and_save().map(|()| false)
            }
        }
    }

    fn notification_matches_active_turn(&self, params: &Value) -> bool {
        notification_id_matches(
            self.snapshot.thread_id.as_deref(),
            params
                .get("threadId")
                .and_then(Value::as_str)
                .or_else(|| params.pointer("/thread/id").and_then(Value::as_str)),
        ) && notification_id_matches(
            self.snapshot.turn_id.as_deref(),
            params
                .get("turnId")
                .and_then(Value::as_str)
                .or_else(|| params.pointer("/turn/id").and_then(Value::as_str)),
        )
    }

    fn handle_item_completed(&mut self, item: &wire::CompletedItem) -> Result<(), CliError> {
        if item.kind.as_deref() != Some("agentMessage") {
            return Ok(());
        }
        let Some(text) = item.text.as_deref() else {
            return Ok(());
        };
        self.snapshot.latest_summary = Some(trim_summary(text));
        if item.phase.as_deref() == Some("final_answer") {
            self.snapshot.final_message = Some(text.to_string());
        }
        self.touch_and_save()
    }

    fn handle_turn_completed(
        &mut self,
        status: Option<&str>,
        error_message: Option<String>,
    ) -> Result<(), CliError> {
        self.clear_pending_approvals();
        let status = status.unwrap_or("completed");
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
                let message = error_message.unwrap_or_else(|| "codex turn failed".to_string());
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

    pub(super) fn clear_pending_approvals(&mut self) {
        self.pending_approvals.clear();
        self.snapshot.pending_approvals.clear();
    }

    async fn handle_server_request(
        &mut self,
        rpc: &mut CodexJsonRpc,
        message: &Value,
        method: &str,
    ) -> Result<(), CliError> {
        let request_id = message
            .get("id")
            .cloned()
            .ok_or_else(|| CliErrorKind::workflow_parse("codex approval request missing id"))?;
        let params = message.get("params").unwrap_or(&Value::Null);
        let Some(approval) =
            approval_from_request(method, wire::value_id_string(&request_id), params)
        else {
            self.reject_unsupported_server_request(rpc, request_id, message, method)
                .await?;
            return Ok(());
        };

        self.record_event(
            method,
            format!("Codex requested approval: {}", approval.title),
            params,
        );
        self.pending_approvals
            .entry(approval.approval_id.clone())
            .or_default()
            .push(PendingApproval {
                request_id,
                method: method.to_string(),
                params: params.clone(),
            });
        upsert_pending_approval(&mut self.snapshot.pending_approvals, approval.clone());
        self.transition(
            CodexRunStatus::WaitingApproval,
            Some(approval.title.as_str()),
            None,
        )?;
        self.controller
            .broadcast_approval(&self.snapshot, &approval);
        Ok(())
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "unsupported request handling records, persists, logs, and replies in one error path"
    )]
    async fn reject_unsupported_server_request(
        &mut self,
        rpc: &mut CodexJsonRpc,
        request_id: Value,
        message: &Value,
        method: &str,
    ) -> Result<(), CliError> {
        self.record_event(
            "server_request_unsupported",
            format!("Unsupported codex server request {method}"),
            message,
        );
        self.touch_and_save()?;
        tracing::warn!(method, "received unsupported codex server request");
        rpc.send_error(
            request_id,
            -32601,
            &format!("Unsupported codex server request {method}"),
        )
        .await
    }
}

fn notification_id_matches(expected: Option<&str>, actual: Option<&str>) -> bool {
    actual.is_none_or(|actual| expected.is_none_or(|expected| expected == actual))
}

#[cfg(test)]
#[path = "worker_tests.rs"]
mod tests;
