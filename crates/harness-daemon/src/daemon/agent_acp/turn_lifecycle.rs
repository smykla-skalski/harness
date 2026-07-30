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
use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncDaemonDb};
use crate::session::types::SessionRole;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::workspace::utc_now;

use super::AcpAgentManagerHandle;

const OPENROUTER_RUNTIME: &str = "openrouter";

/// Ties a durable non-Codex run to a caller-owned lifecycle instead of the
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
    /// Durable non-Codex run store. `None` only in ACP-behavior unit tests that
    /// do not exercise persistence; the production `new` path always supplies
    /// one so every turn is recorded the moment it starts and settles to one
    /// terminal outcome that survives a restart.
    store: Option<Arc<AsyncDaemonDb>>,
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
        store: Arc<AsyncDaemonDb>,
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
        store: Arc<AsyncDaemonDb>,
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
        store: Arc<AsyncDaemonDb>,
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
        store: Arc<AsyncDaemonDb>,
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

    async fn persist_start(
        &self,
        id: &AgentTurnId,
        requested_model: Option<String>,
        source_revision: Option<String>,
    ) -> Result<(), CliError> {
        let Some(store) = &self.store else {
            return Ok(());
        };
        let now = utc_now();
        let correlation = self.correlation.as_ref();
        store
            .record_agent_turn_run_started(&AgentTurnRunSnapshot {
                run_id: self.durable_run_id(id),
                session_id: Some(self.session_id.clone()),
                task_id: correlation.and_then(|c| c.task_id.clone()),
                board_item_id: correlation.and_then(|c| c.board_item_id.clone()),
                workflow_execution_id: correlation.and_then(|c| c.workflow_execution_id.clone()),
                project_dir: self.project_dir.clone(),
                requested_runtime: OPENROUTER_RUNTIME.into(),
                actual_runtime: Some(OPENROUTER_RUNTIME.into()),
                requested_model,
                actual_model: None,
                status: AgentTurnRunStatus::Running,
                source_revision,
                report: None,
                stop_reason: None,
                error: None,
                created_at: now.clone(),
                updated_at: now,
            })
            .await
            .map(|_| ())
    }

    /// Persist an observed terminal settlement exactly once per turn. Only the
    /// columns learned here are set; the store preserves earlier identity and
    /// enrichment and keeps a terminal status sticky. The once-guard keeps
    /// repeated polling of `result`/`failure` side-effect free.
    async fn persist_settlement(
        &self,
        id: &AgentTurnId,
        status: AgentTurnRunStatus,
        actual_model: Option<String>,
        report: Option<String>,
        stop_reason: Option<String>,
        error: Option<String>,
    ) -> Result<(), CliError> {
        let Some(store) = &self.store else {
            return Ok(());
        };
        if self
            .lock_bindings()?
            .get(id)
            .is_some_and(|binding| binding.terminal_persisted)
        {
            return Ok(());
        }
        let now = utc_now();
        store
            .save_agent_turn_run(&AgentTurnRunSnapshot {
                run_id: self.durable_run_id(id),
                session_id: Some(self.session_id.clone()),
                task_id: None,
                board_item_id: None,
                workflow_execution_id: None,
                project_dir: self.project_dir.clone(),
                requested_runtime: OPENROUTER_RUNTIME.into(),
                actual_runtime: Some(OPENROUTER_RUNTIME.into()),
                requested_model: None,
                actual_model,
                status,
                source_revision: None,
                report,
                stop_reason,
                error,
                created_at: now.clone(),
                updated_at: now,
            })
            .await?;
        if let Ok(mut bindings) = self.lock_bindings()
            && let Some(binding) = bindings.get_mut(id)
        {
            binding.terminal_persisted = true;
        }
        Ok(())
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
                requested_model: requested_model.clone(),
                source_revision: source_revision.clone(),
                cancelled: false,
                terminal_persisted: false,
            },
        );
        if let Err(error) = self.persist_start(&id, requested_model, source_revision).await {
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
        Ok(id)
    }

    async fn status(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            return Ok(AgentTurnStatus::Cancelled);
        }
        // Read-only, like the Codex turn runtime: durable terminal state is
        // written once by `result`/`failure`/`cancel`, so status polling never
        // touches the database.
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
        let effective_model = effective_model(&state.config_options);
        self.persist_settlement(
            id,
            AgentTurnRunStatus::Completed,
            effective_model.clone(),
            Some(result.report.clone()),
            Some(result.stop_reason.clone()),
            None,
        )
        .await?;
        Ok(Some(AgentTurnResult {
            correlation_id: id.clone(),
            report: result.report,
            stop_reason: result.stop_reason,
            requested_model: binding.requested_model,
            effective_model,
            source_revision: binding.source_revision,
        }))
    }

    async fn failure(&self, id: &AgentTurnId) -> Result<Option<AgentTurnFailure>, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            // `cancel()` already persisted the terminal cancellation.
            return Ok(Some(AgentTurnFailure::cancelled(
                "OpenRouter turn cancelled",
            )));
        }
        let Some(state) = self.inspect_turn(id)?.session_state else {
            return Ok(None);
        };
        let Some(failure) = state.last_turn_failure else {
            return Ok(None);
        };
        let actual_model = effective_model(&state.config_options);
        let (run_status, stop_reason, error) =
            if failure.category == AgentTurnFailureCategory::Cancelled {
                (AgentTurnRunStatus::Cancelled, Some(failure.detail.clone()), None)
            } else {
                (AgentTurnRunStatus::Failed, None, Some(failure.detail.clone()))
            };
        self.persist_settlement(id, run_status, actual_model, None, stop_reason, error)
            .await?;
        Ok(Some(failure))
    }

    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        if !self.begin_cancellation(id)? {
            return Ok(AgentTurnStatus::Cancelled);
        }
        if let Err(error) = self.manager.stop(id.as_str()) {
            self.rollback_cancellation(id)?;
            return Err(error);
        }
        // A cancelled run keeps `error` NULL and records the reason in
        // `stop_reason`, matching the Codex path so a downstream reader never
        // mistakes a deliberate cancellation for a failure.
        if let Err(error) = self
            .persist_settlement(
                id,
                AgentTurnRunStatus::Cancelled,
                None,
                None,
                Some("cancelled".into()),
                None,
            )
            .await
        {
            // The provider stop already succeeded but the terminal write did
            // not. Drop the local cancellation flag so later polling of
            // `status`/`failure` re-observes the provider-side cancellation and
            // persists it, instead of short-circuiting on the flag forever and
            // leaving the row stuck `running` with its admission unreleased.
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
