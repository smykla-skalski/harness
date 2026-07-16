use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use async_trait::async_trait;
use tokio::sync::broadcast;

use crate::agents::kind::DisconnectReason;
use crate::agents::runtime::event::ConversationEvent;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ensure_shared_db};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as orchestration_service;
use crate::session::types::{AgentStatus, ManagedAgentRef, SessionState};
use crate::workspace::utc_now;

use super::port::{
    AcpManagerPort, AcpRegistrationRequest, AcpRuntimeBinding, AcpWakeAcceptRequest,
};
use super::{AcpAgentSnapshot, AcpOrchestrationRegistration};

pub(super) struct DaemonAcpManagerPort {
    sender: broadcast::Sender<StreamEvent>,
    db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
}

impl DaemonAcpManagerPort {
    pub(super) const fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
    ) -> Self {
        Self {
            sender,
            db,
            async_db,
        }
    }

    fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        ensure_shared_db(&self.db)
    }

    fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
        db.lock().map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "daemon database lock poisoned: {error}"
            )))
        })
    }
}

#[async_trait]
impl AcpManagerPort for DaemonAcpManagerPort {
    fn event_sender(&self) -> broadcast::Sender<StreamEvent> {
        self.sender.clone()
    }

    fn ensure_session_accepts_start(&self, session_id: &str) -> Result<(), CliError> {
        let db = self.db()?;
        let db = Self::lock_db(&db)?;
        if db.load_session_state_for_mutation(session_id)?.is_some()
            && db.session_accepts_managed_agent_start(session_id)?
        {
            return Ok(());
        }
        Err(service::session_not_found(session_id))
    }

    fn register_agent(
        &self,
        request: AcpRegistrationRequest<'_>,
    ) -> Result<AcpOrchestrationRegistration, CliError> {
        let db = self.db()?;
        let db = Self::lock_db(&db)?;
        let Some(mut state) = db.load_session_state_for_mutation(request.session_id)? else {
            return Err(service::session_not_found(request.session_id));
        };
        let now = utc_now();
        let joined_role = orchestration_service::resolve_join_role(
            &state,
            request.request.role,
            request.request.fallback_role,
        )?;
        let agent_id = orchestration_service::apply_join_session(
            &mut state,
            request.display_name,
            &request.descriptor.id,
            joined_role,
            &request.request.capabilities,
            request.agent_session_id,
            &now,
            request.request.persona.as_deref(),
            Some(ManagedAgentRef::acp(request.acp_id)),
        )?;
        let project_id = db
            .project_id_for_session(request.session_id)?
            .ok_or_else(|| service::session_not_found(request.session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&service::build_log_entry(
            request.session_id,
            orchestration_service::log_agent_joined(&agent_id, joined_role, &request.descriptor.id),
            None,
            None,
        ))?;
        db.bump_change(request.session_id)?;
        db.bump_change("global")?;
        Ok(AcpOrchestrationRegistration {
            agent_id,
            display_name: request.display_name.to_string(),
        })
    }

    fn bind_runtime_session(&self, binding: AcpRuntimeBinding<'_>) -> Result<bool, CliError> {
        let db = self.db()?;
        bind_runtime_session_sync(&db, &OwnedRuntimeBinding::from(binding))
    }

    async fn bind_runtime_session_async(
        &self,
        binding: AcpRuntimeBinding<'_>,
    ) -> Result<bool, CliError> {
        if let Some(async_db) = self.async_db.get().cloned() {
            return bind_runtime_session_async(&async_db, binding).await;
        }
        let db = self.db()?;
        let binding = OwnedRuntimeBinding::from(binding);
        tokio::task::spawn_blocking(move || bind_runtime_session_sync(&db, &binding))
            .await
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "join ACP runtime bind task: {error}"
                )))
            })?
    }

    fn rollback_registration(
        &self,
        session_id: &str,
        acp_id: &str,
        agent_id: &str,
        reason_label: &str,
    ) -> Result<bool, CliError> {
        let db = self.db()?;
        let db = Self::lock_db(&db)?;
        let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
            return Ok(false);
        };
        if !should_rollback_incomplete_registration(&state, acp_id, agent_id) {
            return Ok(false);
        }
        let now = utc_now();
        if !orchestration_service::apply_rollback_joined_agent(&mut state, agent_id, &now) {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| service::session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&service::build_log_entry(
            session_id,
            orchestration_service::log_agent_disconnected(agent_id, reason_label),
            None,
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }

    fn sync_disconnect(
        &self,
        snapshot: &AcpAgentSnapshot,
        reason: &DisconnectReason,
        stderr_tail: Option<&String>,
    ) -> Result<bool, CliError> {
        let db = self.db()?;
        let db = Self::lock_db(&db)?;
        let Some(mut state) = db.load_session_state_for_mutation(&snapshot.session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        let rolled_back =
            should_rollback_incomplete_registration(&state, &snapshot.acp_id, &snapshot.agent_id)
                && orchestration_service::apply_rollback_joined_agent(
                    &mut state,
                    &snapshot.agent_id,
                    &now,
                );
        if !rolled_back
            && !orchestration_service::apply_agent_disconnected_with_reason(
                &mut state,
                &snapshot.agent_id,
                reason.clone(),
                stderr_tail.cloned(),
                &now,
            )
        {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(&snapshot.session_id)?
            .ok_or_else(|| service::session_not_found(&snapshot.session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&service::build_log_entry(
            &snapshot.session_id,
            orchestration_service::log_agent_disconnected(&snapshot.agent_id, reason.log_label()),
            None,
            None,
        ))?;
        db.bump_change(&snapshot.session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }

    fn sync_runtime_status(
        &self,
        snapshot: &AcpAgentSnapshot,
        status: AgentStatus,
    ) -> Result<bool, CliError> {
        let db = self.db()?;
        let db = Self::lock_db(&db)?;
        let Some(mut state) = db.load_session_state_for_mutation(&snapshot.session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        if !update_runtime_status(&mut state, snapshot, status, &now) {
            return Ok(false);
        }
        orchestration_service::refresh_session(&mut state, &now);
        let project_id = db
            .project_id_for_session(&snapshot.session_id)?
            .ok_or_else(|| service::session_not_found(&snapshot.session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.bump_change(&snapshot.session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }

    fn project_dir_for_session(&self, session_id: &str) -> Result<Option<String>, CliError> {
        let Some(db) = self.db.get() else {
            return Ok(None);
        };
        Self::lock_db(db)?.project_dir_for_session(session_id)
    }

    fn persist_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
    ) -> Result<(), CliError> {
        Self::lock_db(&self.db()?)?
            .append_conversation_events(session_id, agent_id, runtime, events)
    }

    fn sync_wake_accept(&self, request: AcpWakeAcceptRequest<'_>) -> Result<(), CliError> {
        let db = self.db()?;
        let db = Self::lock_db(&db)?;
        service::record_signal_ack_and_broadcast(
            request.session_id,
            request.agent_id,
            request.signal_id,
            request.result,
            request.project_dir,
            Some(&db),
            Some(&self.sender),
        )
    }

    #[cfg(test)]
    fn daemon_db_slot(&self) -> Option<Arc<OnceLock<Arc<Mutex<DaemonDb>>>>> {
        Some(Arc::clone(&self.db))
    }
}

#[derive(Clone)]
struct OwnedRuntimeBinding {
    session_id: String,
    acp_id: String,
    runtime_name: String,
    agent_session_id: String,
}

impl From<AcpRuntimeBinding<'_>> for OwnedRuntimeBinding {
    fn from(binding: AcpRuntimeBinding<'_>) -> Self {
        Self {
            session_id: binding.session_id.to_string(),
            acp_id: binding.acp_id.to_string(),
            runtime_name: binding.runtime_name.to_string(),
            agent_session_id: binding.agent_session_id.to_string(),
        }
    }
}

async fn bind_runtime_session_async(
    db: &AsyncDaemonDb,
    binding: AcpRuntimeBinding<'_>,
) -> Result<bool, CliError> {
    let now = utc_now();
    let managed_agent = ManagedAgentRef::acp(binding.acp_id);
    let registered = match db
        .update_session_state_immediate(binding.session_id, |state| {
            orchestration_service::apply_register_agent_runtime_session(
                state,
                binding.runtime_name,
                &managed_agent,
                binding.agent_session_id,
                &now,
            )
        })
        .await
    {
        Ok(registered) => registered,
        Err(error) if error.code() == "KSRCLI090" => return Ok(false),
        Err(error) => return Err(error),
    };
    if registered {
        db.bump_change(binding.session_id).await?;
        db.bump_change("global").await?;
    }
    Ok(registered)
}

fn bind_runtime_session_sync(
    db: &Arc<Mutex<DaemonDb>>,
    binding: &OwnedRuntimeBinding,
) -> Result<bool, CliError> {
    let db = DaemonAcpManagerPort::lock_db(db)?;
    let Some(mut state) = db.load_session_state_for_mutation(&binding.session_id)? else {
        return Ok(false);
    };
    let registered = orchestration_service::apply_register_agent_runtime_session(
        &mut state,
        &binding.runtime_name,
        &ManagedAgentRef::acp(binding.acp_id.as_str()),
        &binding.agent_session_id,
        &utc_now(),
    )?;
    if registered {
        let project_id = db
            .project_id_for_session(&binding.session_id)?
            .ok_or_else(|| service::session_not_found(&binding.session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.bump_change(&binding.session_id)?;
        db.bump_change("global")?;
    }
    Ok(registered)
}

fn update_runtime_status(
    state: &mut SessionState,
    snapshot: &AcpAgentSnapshot,
    status: AgentStatus,
    now: &str,
) -> bool {
    let Some(agent) = state.agents.get_mut(&snapshot.agent_id) else {
        return false;
    };
    if agent.managed_agent != Some(ManagedAgentRef::acp(snapshot.acp_id.as_str()))
        || agent.status == status
    {
        return false;
    }
    agent.status = status;
    agent.updated_at = now.to_string();
    true
}

fn should_rollback_incomplete_registration(
    state: &SessionState,
    acp_id: &str,
    agent_id: &str,
) -> bool {
    state.agents.get(agent_id).is_some_and(|agent| {
        agent.managed_agent.as_ref() == Some(&ManagedAgentRef::acp(acp_id))
            && agent.agent_session_id.is_none()
    })
}
