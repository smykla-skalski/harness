use serde_json::json;

use crate::daemon::protocol::{CodexApprovalDecision, CodexResolvedApproval, CodexRunStatus};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::active_runs::CodexControlMessage;
use super::approvals::approval_result;
use super::rpc::CodexJsonRpc;
use super::wire;
use super::worker::CodexRunWorker;

impl CodexRunWorker {
    pub(super) async fn handle_control(
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
            let result = approval_result(&pending.method, decision, &pending.params);
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
        self.record_event(
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
}
