use std::collections::HashMap;

use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::daemon::codex_transport::CodexTransport;
use crate::daemon::protocol::{
    CodexApprovalDecision, CodexResolvedApproval, CodexRunSnapshot, CodexRunStatus,
};
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::active_runs::CodexControlMessage;
use super::approvals::{
    approval_from_request, approval_policy, approval_result, mode_instructions, thread_sandbox,
    trim_summary, turn_sandbox_policy, upsert_pending_approval,
};
use super::handle::{CodexControllerHandle, record_snapshot_event};
use super::rpc::CodexJsonRpc;
use super::wire::{self, AppServerNotification};

pub(super) struct CodexRunWorker {
    controller: CodexControllerHandle,
    snapshot: CodexRunSnapshot,
    control_rx: mpsc::UnboundedReceiver<CodexControlMessage>,
    pending_approvals: HashMap<String, Vec<PendingApproval>>,
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
        let _ = rpc.request(wire::METHOD_INITIALIZE, params).await?;
        Ok(())
    }

    async fn start_or_resume_thread(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let method = if self.snapshot.thread_id.is_some() {
            wire::METHOD_THREAD_RESUME
        } else {
            wire::METHOD_THREAD_START
        };
        let params = wire::thread_params(wire::ThreadParamsInput {
            cwd: &self.snapshot.project_dir,
            sandbox: thread_sandbox(self.snapshot.mode),
            approval_policy: approval_policy(self.snapshot.mode),
            developer_instructions: mode_instructions(self.snapshot.mode),
            thread_id: self.snapshot.thread_id.as_deref(),
            model: self.snapshot.model.as_deref(),
            effort: self.snapshot.effort.as_deref(),
        })?;

        let result = rpc.request(method, params).await?;
        let thread_id = wire::thread_id_from_result(&result).ok_or_else(|| {
            CliErrorKind::workflow_parse("codex thread response missing thread.id")
        })?;
        self.snapshot.thread_id = Some(thread_id.to_string());
        self.snapshot.latest_summary = Some(format!("Thread {thread_id} ready"));
        self.record_event(method, format!("Codex thread {thread_id} ready"), &result);
        self.touch_and_save()?;
        Ok(())
    }

    async fn start_turn(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let thread_id = self.thread_id()?;
        let params = wire::turn_start_params(
            &thread_id,
            &self.snapshot.project_dir,
            &self.snapshot.prompt,
            approval_policy(self.snapshot.mode),
            turn_sandbox_policy(self.snapshot.mode, &self.snapshot.project_dir),
        )?;
        let result = rpc.request(wire::METHOD_TURN_START, params).await?;
        let turn_id = wire::turn_id_from_result(&result)
            .ok_or_else(|| CliErrorKind::workflow_parse("codex turn response missing turn.id"))?;
        self.snapshot.turn_id = Some(turn_id.to_string());
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
        let notification = wire::parse_notification(method, params);
        self.record_event(method, wire::notification_summary(method, params), params);
        match notification {
            AppServerNotification::TurnStarted { turn_id } => {
                if let Some(turn_id) = turn_id {
                    self.snapshot.turn_id = Some(turn_id.to_string());
                    self.snapshot.latest_summary = Some(format!("Turn {turn_id} is running"));
                    self.touch_and_save()?;
                }
                Ok(false)
            }
            AppServerNotification::AgentMessageDelta { delta } => {
                if let Some(delta) = delta {
                    self.agent_message_delta.push_str(&delta);
                    self.snapshot.latest_summary = Some(trim_summary(&self.agent_message_delta));
                    self.touch_and_save()?;
                }
                Ok(false)
            }
            AppServerNotification::ItemCompleted { item } => {
                self.handle_item_completed(&item)?;
                Ok(false)
            }
            AppServerNotification::TurnCompleted {
                status,
                error_message,
            } => {
                self.handle_turn_completed(status.as_deref(), error_message)?;
                Ok(true)
            }
            AppServerNotification::Error { message } => {
                let message = message
                    .as_deref()
                    .unwrap_or("codex app-server reported an error");
                self.fail(message);
                Ok(true)
            }
            AppServerNotification::Other => self.touch_and_save().map(|()| false),
        }
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

    async fn handle_control(
        &mut self,
        rpc: &mut CodexJsonRpc,
        control: CodexControlMessage,
    ) -> Result<bool, CliError> {
        match control {
            CodexControlMessage::Approval {
                approval_id,
                decision,
                ack,
            } => {
                let result = self
                    .resolve_approval(rpc, &approval_id, decision)
                    .await
                    .map(|()| self.snapshot.clone());
                let _ = ack.send(result);
                Ok(false)
            }
            CodexControlMessage::Steer { prompt, ack } => {
                let result = self
                    .steer(rpc, &prompt)
                    .await
                    .map(|()| self.snapshot.clone());
                let _ = ack.send(result);
                Ok(false)
            }
            CodexControlMessage::Interrupt { ack } => {
                let result = self.interrupt(rpc).await.map(|()| self.snapshot.clone());
                let _ = ack.send(result);
                Ok(false)
            }
            CodexControlMessage::Stop { ack } => {
                let result = self.stop(rpc).await.map(|()| self.snapshot.clone());
                let should_stop = result.is_ok();
                let _ = ack.send(result);
                Ok(should_stop)
            }
        }
    }

    async fn resolve_approval(
        &mut self,
        rpc: &mut CodexJsonRpc,
        approval_id: &str,
        decision: CodexApprovalDecision,
    ) -> Result<(), CliError> {
        let Some(pending_requests) = self.pending_approvals.remove(approval_id) else {
            return Err(CliErrorKind::session_not_active(format!(
                "codex approval '{approval_id}' is not pending"
            ))
            .into());
        };
        for pending in pending_requests {
            let result = approval_result(&pending.method, decision);
            rpc.send_response(pending.request_id, result).await?;
        }
        self.snapshot
            .pending_approvals
            .retain(|approval| approval.approval_id != approval_id);
        self.snapshot
            .resolved_approvals
            .push(CodexResolvedApproval {
                approval_id: approval_id.to_string(),
                decision,
                resolved_at: utc_now(),
            });
        self.snapshot.status = CodexRunStatus::Running;
        self.snapshot.latest_summary = Some(format!("Approval {approval_id} resolved"));
        self.record_event(
            "approval/resolved",
            format!("Approval {approval_id} resolved"),
            &json!({
                "approvalId": approval_id,
                "decision": decision,
            }),
        );
        self.touch_save_and_sync_orchestration()
    }

    async fn steer(&mut self, rpc: &mut CodexJsonRpc, prompt: &str) -> Result<(), CliError> {
        let thread_id = self.thread_id()?;
        let turn_id = self.turn_id()?;
        let params = wire::turn_steer_params(&thread_id, &turn_id, prompt)?;
        let _ = rpc
            .send_request(wire::METHOD_TURN_STEER, params.clone())
            .await?;
        self.snapshot.latest_summary = Some("Steering prompt sent".to_string());
        self.record_event(
            wire::METHOD_TURN_STEER,
            "Steering prompt sent".to_string(),
            &params,
        );
        self.touch_save_and_sync_orchestration()
    }

    async fn interrupt(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let thread_id = self.thread_id()?;
        let turn_id = self.turn_id()?;
        let params = wire::turn_interrupt_params(&thread_id, &turn_id)?;
        let _ = rpc
            .send_request(wire::METHOD_TURN_INTERRUPT, params.clone())
            .await?;
        self.snapshot.latest_summary = Some("Interrupt requested".to_string());
        self.record_event(
            wire::METHOD_TURN_INTERRUPT,
            "Interrupt requested".to_string(),
            &params,
        );
        self.touch_save_and_sync_orchestration()
    }

    async fn stop(&mut self, rpc: &mut CodexJsonRpc) -> Result<(), CliError> {
        let thread_id = self.snapshot.thread_id.clone();
        let turn_id = self.snapshot.turn_id.clone();
        let interrupt_result = match (&thread_id, &turn_id) {
            (Some(thread_id), Some(turn_id)) => {
                let params = wire::turn_interrupt_params(thread_id, turn_id)?;
                rpc.send_request(wire::METHOD_TURN_INTERRUPT, params)
                    .await
                    .map(|_| ())
            }
            _ => Ok(()),
        };
        let interrupt_error = interrupt_result.as_ref().err().map(ToString::to_string);
        self.pending_approvals.clear();
        self.snapshot.pending_approvals.clear();
        record_snapshot_event(
            &mut self.snapshot,
            "agent/stop",
            "Codex agent stopped".to_string(),
            &json!({
                "threadId": thread_id,
                "turnId": turn_id,
                "interruptError": interrupt_error,
            }),
        );
        self.transition(CodexRunStatus::Cancelled, Some("Codex agent stopped"), None)
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
        self.touch_and_save()?;
        self.controller
            .sync_orchestration_status_for_run(&self.snapshot)
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
        if let Err(error) = self
            .controller
            .sync_orchestration_status_for_run(&self.snapshot)
        {
            tracing::warn!(%error, "failed to sync codex failure status to session agent");
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

    fn touch_save_and_sync_orchestration(&mut self) -> Result<(), CliError> {
        self.touch_and_save()?;
        self.controller
            .sync_orchestration_status_for_run(&self.snapshot)
    }

    fn record_event(&mut self, kind: &str, summary: String, payload: &Value) {
        record_snapshot_event(&mut self.snapshot, kind, summary, payload);
    }
}

#[cfg(test)]
mod tests {
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
}
