use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};

use async_trait::async_trait;

use crate::agents::turn::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnId, AgentTurnRequest, AgentTurnResult,
    AgentTurnRuntime, AgentTurnStatus,
};
use crate::daemon::agent_acp::{
    AcpAgentInspectResponse, AcpAgentSnapshot, AcpAgentStartRequest, AcpSessionConfigOptionState,
};
use crate::session::types::SessionRole;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::AcpAgentManagerHandle;

const OPENROUTER_RUNTIME: &str = "openrouter";

trait OpenRouterTurnManager: Send + Sync {
    fn start(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError>;

    fn inspect(&self, session_id: &str) -> Result<AcpAgentInspectResponse, CliError>;

    fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError>;
}

impl OpenRouterTurnManager for AcpAgentManagerHandle {
    fn start(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError> {
        Self::start(self, session_id, request)
    }

    fn inspect(&self, session_id: &str) -> Result<AcpAgentInspectResponse, CliError> {
        Self::inspect(self, Some(session_id))
    }

    fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        Self::stop(self, acp_id)
    }
}

#[derive(Debug, Clone)]
struct OpenRouterTurnBinding {
    requested_model: Option<String>,
    source_revision: Option<String>,
    cancelled: bool,
}

#[derive(Clone)]
pub struct OpenRouterAgentTurnRuntime {
    manager: Arc<dyn OpenRouterTurnManager>,
    session_id: String,
    project_dir: Option<String>,
    bindings: Arc<Mutex<BTreeMap<AgentTurnId, OpenRouterTurnBinding>>>,
}

impl OpenRouterAgentTurnRuntime {
    #[must_use]
    pub fn new(
        manager: AcpAgentManagerHandle,
        session_id: impl Into<String>,
        project_dir: Option<String>,
    ) -> Self {
        Self::with_manager(Arc::new(manager), session_id.into(), project_dir)
    }

    fn with_manager(
        manager: Arc<dyn OpenRouterTurnManager>,
        session_id: String,
        project_dir: Option<String>,
    ) -> Self {
        Self {
            manager,
            session_id,
            project_dir,
            bindings: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    fn lock_bindings(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<AgentTurnId, OpenRouterTurnBinding>>, CliError> {
        self.bindings.lock().map_err(|_| {
            CliErrorKind::workflow_io("OpenRouter turn binding lock is poisoned".to_string()).into()
        })
    }

    fn binding(&self, id: &AgentTurnId) -> Result<OpenRouterTurnBinding, CliError> {
        self.lock_bindings()?.get(id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!("OpenRouter turn '{id}' is unknown")).into()
        })
    }

    fn begin_cancellation(&self, id: &AgentTurnId) -> Result<bool, CliError> {
        let mut bindings = self.lock_bindings()?;
        let binding = bindings.get_mut(id).ok_or_else(|| {
            CliErrorKind::session_not_active(format!("OpenRouter turn '{id}' is unknown"))
        })?;
        if binding.cancelled {
            return Ok(false);
        }
        binding.cancelled = true;
        Ok(true)
    }

    fn rollback_cancellation(&self, id: &AgentTurnId) -> Result<(), CliError> {
        let mut bindings = self.lock_bindings()?;
        let binding = bindings.get_mut(id).ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "OpenRouter turn '{id}' disappeared during cancellation rollback"
            ))
        })?;
        binding.cancelled = false;
        Ok(())
    }

    fn inspect_turn(
        &self,
        id: &AgentTurnId,
    ) -> Result<crate::daemon::agent_acp::AcpAgentInspectSnapshot, CliError> {
        self.manager
            .inspect(&self.session_id)?
            .agents
            .into_iter()
            .find(|agent| agent.acp_id == id.as_str())
            .ok_or_else(|| {
                CliErrorKind::session_not_active(format!(
                    "OpenRouter turn '{id}' is not active in session '{}'",
                    self.session_id
                ))
                .into()
            })
    }
}

#[async_trait]
impl AgentTurnRuntime for OpenRouterAgentTurnRuntime {
    fn runtime(&self) -> &'static str {
        OPENROUTER_RUNTIME
    }

    async fn start(&self, request: AgentTurnRequest) -> Result<AgentTurnId, CliError> {
        let request = request.into_validated()?;
        let source_revision = request
            .pull_request
            .as_ref()
            .map(|pull_request| pull_request.head_revision.clone());
        let requested_model = request.requested_model.clone();
        let snapshot = self.manager.start(
            &self.session_id,
            &AcpAgentStartRequest {
                agent: OPENROUTER_RUNTIME.into(),
                role: SessionRole::Worker,
                prompt: Some(request.prompt),
                project_dir: self.project_dir.clone(),
                name: Some("OpenRouter report turn".into()),
                model: requested_model.clone(),
                resume_disabled: true,
                ..AcpAgentStartRequest::default()
            },
        )?;
        let id = AgentTurnId::new(snapshot.acp_id)?;
        self.lock_bindings()?.insert(
            id.clone(),
            OpenRouterTurnBinding {
                requested_model,
                source_revision,
                cancelled: false,
            },
        );
        Ok(id)
    }

    async fn status(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            return Ok(AgentTurnStatus::Cancelled);
        }
        let state = self.inspect_turn(id)?.session_state.unwrap_or_default();
        if let Some(failure) = state.last_turn_failure {
            return Ok(if failure.category == AgentTurnFailureCategory::Cancelled {
                AgentTurnStatus::Cancelled
            } else {
                AgentTurnStatus::Failed
            });
        }
        if state.last_turn_result.is_some() {
            Ok(AgentTurnStatus::Completed)
        } else {
            Ok(AgentTurnStatus::Running)
        }
    }

    async fn result(&self, id: &AgentTurnId) -> Result<Option<AgentTurnResult>, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            return Ok(None);
        }
        let snapshot = self.inspect_turn(id)?;
        let state = snapshot.session_state.unwrap_or_default();
        let Some(result) = state.last_turn_result else {
            return Ok(None);
        };
        Ok(Some(AgentTurnResult {
            correlation_id: id.clone(),
            report: result.report,
            stop_reason: result.stop_reason,
            requested_model: binding.requested_model,
            effective_model: effective_model(&state.config_options),
            source_revision: binding.source_revision,
        }))
    }

    async fn failure(&self, id: &AgentTurnId) -> Result<Option<AgentTurnFailure>, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            return Ok(Some(AgentTurnFailure::cancelled(
                "OpenRouter turn cancelled",
            )));
        }
        Ok(self
            .inspect_turn(id)?
            .session_state
            .and_then(|state| state.last_turn_failure))
    }

    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        if !self.begin_cancellation(id)? {
            return Ok(AgentTurnStatus::Cancelled);
        }
        if let Err(error) = self.manager.stop(id.as_str()) {
            self.rollback_cancellation(id)?;
            return Err(error);
        }
        Ok(AgentTurnStatus::Cancelled)
    }
}

fn effective_model(options: &[AcpSessionConfigOptionState]) -> Option<String> {
    options
        .iter()
        .find(|option| option.id == "model")
        .map(|option| option.current_value.clone())
}

#[cfg(test)]
#[path = "turn_lifecycle_tests.rs"]
mod tests;
