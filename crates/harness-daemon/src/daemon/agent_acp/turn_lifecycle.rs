use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::agents::turn::{AgentTurnId, AgentTurnRequest, AgentTurnRuntime};
use crate::daemon::agent_acp::{
    AcpAgentInspectResponse, AcpAgentSessionState, AcpAgentSnapshot, AcpAgentStartRequest,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::AcpAgentManagerHandle;
use crate::daemon::db::task_board::prelude::AutomationKillSwitchQueries;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::session::types::SessionRole;

mod persistence;

const OPENROUTER_RUNTIME: &str = "openrouter";

mod agent_turn_runtime;

/// Ties a durable agent-turn run to a caller-owned lifecycle instead of the
/// self-generated ACP id. The task-board coordinator drives runs by an attempt
/// `idempotency_key` (the managed run id, which doubles as the concurrency
/// admission's `managed_worker_id`), so when it owns the turn it supplies that
/// id here and the run records, resumes, and releases its admission against the
/// attempt rather than an id the coordinator never sees. Absent correlation
/// keeps the merged behavior: the run keys on the ACP turn id.
#[derive(Debug, Clone)]
#[expect(
    clippy::struct_field_names,
    reason = "fields mirror the agent_turn_runs store columns; renaming them off their column names would obscure the mapping"
)]
pub(crate) struct OpenRouterRunCorrelation {
    pub run_id: String,
    pub board_item_id: Option<String>,
    pub workflow_execution_id: Option<String>,
    pub task_id: Option<String>,
}

trait OpenRouterTurnManager: Send + Sync {
    fn start(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError>;

    fn inspect(&self, session_id: &str) -> Result<AcpAgentInspectResponse, CliError>;

    /// The last state a turn reported, readable after its session detached.
    fn detached_turn_state(
        &self,
        session_id: &str,
        acp_id: &str,
    ) -> Result<Option<AcpAgentSessionState>, CliError>;

    fn runtime_session_id(
        &self,
        session_id: &str,
        acp_id: &str,
    ) -> Result<Option<String>, CliError>;

    fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError>;
}

impl OpenRouterTurnManager for AcpAgentManagerHandle {
    fn start(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError> {
        Self::start_with_pooling_disabled(self, session_id, request, false)
    }

    fn inspect(&self, session_id: &str) -> Result<AcpAgentInspectResponse, CliError> {
        Self::inspect(self, Some(session_id))
    }

    fn detached_turn_state(
        &self,
        session_id: &str,
        acp_id: &str,
    ) -> Result<Option<AcpAgentSessionState>, CliError> {
        Self::detached_turn_state(self, session_id, acp_id)
    }

    fn runtime_session_id(
        &self,
        session_id: &str,
        acp_id: &str,
    ) -> Result<Option<String>, CliError> {
        Self::runtime_session_id(self, session_id, acp_id)
    }

    fn stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        Self::stop(self, acp_id)
    }
}

#[derive(Debug, Clone)]
pub(super) struct OpenRouterTurnBinding {
    requested_model: Option<String>,
    source_revision: Option<String>,
    cancelled: bool,
    /// Set once the terminal outcome has been written durably, so repeated
    /// polling of `result`/`failure` stays side-effect free after the first
    /// observed transition.
    terminal_persisted: bool,
}

#[derive(Clone)]
pub struct OpenRouterAgentTurnRuntime {
    manager: Arc<dyn OpenRouterTurnManager>,
    session_id: String,
    project_dir: Option<String>,
    bindings: Arc<Mutex<BTreeMap<AgentTurnId, OpenRouterTurnBinding>>>,
    /// Durable agent-turn run store. `None` only in ACP-behavior unit tests that
    /// do not exercise persistence; the production `new` path always supplies
    /// one so every turn is recorded the moment it starts and settles to one
    /// terminal outcome that survives a restart.
    store: Option<Arc<AsyncDaemonDbHandle>>,
    /// Caller-owned run identity. `None` keeps the run keyed on the ACP turn id;
    /// `Some` keys it on the coordinator's attempt lifecycle. One turn runs per
    /// instance, so a single correlation covers it.
    correlation: Option<OpenRouterRunCorrelation>,
}

impl OpenRouterAgentTurnRuntime {
    #[must_use]
    pub fn new(
        manager: AcpAgentManagerHandle,
        session_id: impl Into<String>,
        project_dir: Option<String>,
        store: Arc<AsyncDaemonDbHandle>,
    ) -> Self {
        Self {
            manager: Arc::new(manager),
            session_id: session_id.into(),
            project_dir,
            bindings: Arc::new(Mutex::new(BTreeMap::new())),
            store: Some(store),
            correlation: None,
        }
    }

    /// Build a runtime whose durable run keys on a caller-owned identity. The
    /// task-board coordinator uses this so the run correlates to its attempt.
    #[must_use]
    pub(crate) fn new_correlated(
        manager: AcpAgentManagerHandle,
        session_id: impl Into<String>,
        project_dir: Option<String>,
        store: Arc<AsyncDaemonDbHandle>,
        correlation: OpenRouterRunCorrelation,
    ) -> Self {
        Self {
            manager: Arc::new(manager),
            session_id: session_id.into(),
            project_dir,
            bindings: Arc::new(Mutex::new(BTreeMap::new())),
            store: Some(store),
            correlation: Some(correlation),
        }
    }

    #[cfg(test)]
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
            store: None,
            correlation: None,
        }
    }

    #[cfg(test)]
    fn with_manager_and_store(
        manager: Arc<dyn OpenRouterTurnManager>,
        session_id: String,
        project_dir: Option<String>,
        store: Arc<AsyncDaemonDbHandle>,
    ) -> Self {
        Self {
            manager,
            session_id,
            project_dir,
            bindings: Arc::new(Mutex::new(BTreeMap::new())),
            store: Some(store),
            correlation: None,
        }
    }

    #[cfg(test)]
    fn with_manager_store_and_correlation(
        manager: Arc<dyn OpenRouterTurnManager>,
        session_id: String,
        project_dir: Option<String>,
        store: Arc<AsyncDaemonDbHandle>,
        correlation: OpenRouterRunCorrelation,
    ) -> Self {
        Self {
            manager,
            session_id,
            project_dir,
            bindings: Arc::new(Mutex::new(BTreeMap::new())),
            store: Some(store),
            correlation: Some(correlation),
        }
    }

    /// The durable `run_id` for this turn: the caller-owned correlation id when
    /// present, else the ACP turn id.
    fn durable_run_id(&self, id: &AgentTurnId) -> String {
        self.correlation
            .as_ref()
            .map_or_else(|| id.as_str().to_string(), |c| c.run_id.clone())
    }

    fn lock_bindings(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<AgentTurnId, OpenRouterTurnBinding>>, CliError> {
        self.bindings.lock().map_err(|_| {
            CliErrorKind::workflow_io("OpenRouter turn binding lock is poisoned".to_string()).into()
        })
    }

    pub(super) fn binding(&self, id: &AgentTurnId) -> Result<OpenRouterTurnBinding, CliError> {
        self.lock_bindings()?.get(id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!("OpenRouter turn '{id}' is unknown")).into()
        })
    }

    pub(super) fn runtime_session_id(&self, id: &AgentTurnId) -> Result<String, CliError> {
        self.binding(id)?;
        self.manager
            .runtime_session_id(&self.session_id, id.as_str())?
            .ok_or_else(|| {
                CliErrorKind::session_not_active(format!(
                    "OpenRouter turn '{id}' has no bound provider session"
                ))
                .into()
            })
    }

    pub(super) async fn start_with_resume_session(
        &self,
        request: AgentTurnRequest,
        resume_session_id: Option<String>,
    ) -> Result<AgentTurnId, CliError> {
        if let Some(store) = &self.store
            && store.automation_kill_switch_engaged().await?
        {
            return Err(
                CliErrorKind::invalid_transition("automation kill switch is engaged").into(),
            );
        }
        let expected_resume_session_id = resume_session_id.clone();
        let request = request.into_validated()?;
        let source_revision = request
            .pull_request
            .as_ref()
            .map(|pull_request| pull_request.head_revision.clone());
        let capabilities = if request.pull_request.is_some() {
            vec![super::REPORT_ONLY_REVIEW_CAPABILITY.to_string()]
        } else {
            Vec::new()
        };
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
                capabilities,
                resume_disabled: resume_session_id.is_none(),
                resume_session_id,
                ..AcpAgentStartRequest::default()
            },
        )?;
        let id = AgentTurnId::new(snapshot.acp_id)?;
        if let Some(expected) = expected_resume_session_id {
            self.verify_resumed_session(&id, &expected)?;
        }
        self.lock_bindings()?.insert(
            id.clone(),
            OpenRouterTurnBinding {
                requested_model: requested_model.clone(),
                source_revision: source_revision.clone(),
                cancelled: false,
                terminal_persisted: false,
            },
        );
        if let Err(error) = self
            .persist_start(&id, requested_model, source_revision)
            .await
        {
            // The remote turn is already running and the binding is inserted,
            // but the run could not be recorded durably. Leaving both in place
            // would strand agent work and let a retry start a second turn -- the
            // exact double-start this durable tracking exists to prevent. Undo
            // both on a best-effort basis, then surface the persistence error.
            if let Ok(mut bindings) = self.lock_bindings() {
                bindings.remove(&id);
            }
            if let Err(stop_error) = self.manager.stop(id.as_str()) {
                tracing::warn!(
                    turn_id = %id,
                    %stop_error,
                    "failed to stop OpenRouter turn after its start could not be recorded; provider work may be orphaned"
                );
            }
            return Err(error);
        }
        if let Some(store) = &self.store
            && store.automation_kill_switch_engaged().await?
        {
            <Self as AgentTurnRuntime>::cancel(self, &id).await?;
            return Err(CliErrorKind::invalid_transition(
                "automation kill switch engaged while starting an agent turn",
            )
            .into());
        }
        Ok(id)
    }

    fn verify_resumed_session(
        &self,
        id: &AgentTurnId,
        expected_session_id: &str,
    ) -> Result<(), CliError> {
        let actual = self
            .manager
            .runtime_session_id(&self.session_id, id.as_str());
        if actual
            .as_ref()
            .is_ok_and(|actual| actual.as_deref() == Some(expected_session_id))
        {
            return Ok(());
        }
        if let Err(error) = self.manager.stop(id.as_str()) {
            tracing::warn!(
                turn_id = %id,
                %error,
                "failed to stop OpenRouter turn after exact session resume was not honored"
            );
        }
        Err(CliErrorKind::session_not_active(format!(
            "OpenRouter turn '{id}' did not resume provider session '{expected_session_id}'"
        ))
        .into())
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

#[cfg(test)]
#[path = "turn_lifecycle_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "turn_lifecycle/reconciliation_tests.rs"]
mod reconciliation_tests;

#[cfg(test)]
#[path = "turn_lifecycle/persistence_tests.rs"]
mod persistence_tests;
