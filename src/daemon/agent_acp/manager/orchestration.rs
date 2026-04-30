use tokio::task;

use super::catalog;
use super::orchestration_service;
use super::service;
use super::utc_now;
use super::{
    AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest, AcpOrchestrationRegistration,
};
use crate::agents::kind::DisconnectReason;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{AgentStatus, ManagedAgentRef};

impl AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) fn register_orchestration_agent(
        &self,
        session_id: &str,
        acp_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &catalog::AcpAgentDescriptor,
        display_name: &str,
        agent_session_id: Option<&str>,
    ) -> Result<AcpOrchestrationRegistration, CliError> {
        let db =
            self.state.db.get().cloned().ok_or_else(|| {
                CliErrorKind::workflow_io("daemon database unavailable".to_string())
            })?;
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
            return Err(service::session_not_found(session_id));
        };
        let now = utc_now();
        let joined_role =
            orchestration_service::resolve_join_role(&state, request.role, request.fallback_role)?;
        let agent_id = orchestration_service::apply_join_session(
            &mut state,
            display_name,
            &descriptor.id,
            joined_role,
            &request.capabilities,
            agent_session_id,
            &now,
            request.persona.as_deref(),
            Some(ManagedAgentRef::acp(acp_id)),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| service::session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&service::build_log_entry(
            session_id,
            orchestration_service::log_agent_joined(&agent_id, joined_role, &descriptor.id),
            None,
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        Ok(AcpOrchestrationRegistration {
            agent_id,
            display_name: display_name.to_string(),
        })
    }

    pub(in crate::daemon::agent_acp) fn bind_orchestration_runtime_session(
        &self,
        session_id: &str,
        acp_id: &str,
        runtime_name: &str,
        agent_session_id: &str,
    ) -> Result<bool, CliError> {
        let db =
            self.state.db.get().cloned().ok_or_else(|| {
                CliErrorKind::workflow_io("daemon database unavailable".to_string())
            })?;
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        let registered = orchestration_service::apply_register_agent_runtime_session(
            &mut state,
            runtime_name,
            &ManagedAgentRef::acp(acp_id),
            agent_session_id,
            &now,
        )?;
        if !registered {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| service::session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }

    pub(in crate::daemon::agent_acp) async fn bind_orchestration_runtime_session_async(
        &self,
        session_id: &str,
        acp_id: &str,
        runtime_name: &str,
        agent_session_id: &str,
    ) -> Result<bool, CliError> {
        if let Some(async_db) = self.state.async_db.get().cloned() {
            let now = utc_now();
            let managed_agent = ManagedAgentRef::acp(acp_id);
            let registered = match async_db
                .update_session_state_immediate(session_id, |state| {
                    orchestration_service::apply_register_agent_runtime_session(
                        state,
                        runtime_name,
                        &managed_agent,
                        agent_session_id,
                        &now,
                    )
                })
                .await
            {
                Ok(registered) => registered,
                Err(error) if error.code() == "KSRCLI090" => return Ok(false),
                Err(error) => return Err(error),
            };
            if !registered {
                return Ok(false);
            }
            async_db.bump_change(session_id).await?;
            async_db.bump_change("global").await?;
            return Ok(true);
        }

        let manager = self.clone();
        let session_id = session_id.to_string();
        let acp_id = acp_id.to_string();
        let runtime_name = runtime_name.to_string();
        let agent_session_id = agent_session_id.to_string();
        task::spawn_blocking(move || {
            manager.bind_orchestration_runtime_session(
                &session_id,
                &acp_id,
                &runtime_name,
                &agent_session_id,
            )
        })
        .await
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "join ACP runtime bind task: {error}"
            )))
        })?
    }

    pub(in crate::daemon::agent_acp) fn sync_orchestration_disconnect(
        &self,
        snapshot: &AcpAgentSnapshot,
    ) -> Result<bool, CliError> {
        let Some((reason, stderr_tail)) = disconnected_status_parts(snapshot) else {
            return Ok(false);
        };
        self.persist_orchestration_disconnect(snapshot, reason, stderr_tail)
    }

    fn persist_orchestration_disconnect(
        &self,
        snapshot: &AcpAgentSnapshot,
        reason: &DisconnectReason,
        stderr_tail: Option<&String>,
    ) -> Result<bool, CliError> {
        let db =
            self.state.db.get().cloned().ok_or_else(|| {
                CliErrorKind::workflow_io("daemon database unavailable".to_string())
            })?;
        let db = db.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}"))
        })?;
        let Some(mut state) = db.load_session_state_for_mutation(&snapshot.session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        let disconnected = orchestration_service::apply_agent_disconnected_with_reason(
            &mut state,
            &snapshot.agent_id,
            reason.clone(),
            stderr_tail.cloned(),
            &now,
        );
        if !disconnected {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(&snapshot.session_id)?
            .ok_or_else(|| service::session_not_found(&snapshot.session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&service::build_log_entry(
            &snapshot.session_id,
            orchestration_service::log_agent_disconnected(
                &snapshot.agent_id,
                disconnect_reason_label(reason),
            ),
            None,
            None,
        ))?;
        db.bump_change(&snapshot.session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }

    pub(in crate::daemon::agent_acp) fn sync_orchestration_disconnect_best_effort(
        &self,
        snapshot: &AcpAgentSnapshot,
    ) {
        if let Err(error) = self.sync_orchestration_disconnect(snapshot) {
            warn_disconnect_sync_failure(snapshot, &error);
        }
    }
}

fn disconnected_status_parts(
    snapshot: &AcpAgentSnapshot,
) -> Option<(&DisconnectReason, Option<&String>)> {
    let AgentStatus::Disconnected {
        reason,
        stderr_tail,
    } = &snapshot.status
    else {
        return None;
    };
    Some((reason, stderr_tail.as_ref()))
}

fn disconnect_reason_label(reason: &DisconnectReason) -> &'static str {
    reason.log_label()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion in leaf logging helper"
)]
fn warn_disconnect_sync_failure(snapshot: &AcpAgentSnapshot, error: &CliError) {
    tracing::warn!(
        acp_id = %snapshot.acp_id,
        session_id = %snapshot.session_id,
        agent_id = %snapshot.agent_id,
        %error,
        "failed to sync ACP disconnect into session orchestration"
    );
}
