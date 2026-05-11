use std::convert::identity;
use std::env::var;
use std::future::Future;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use tokio::runtime::{Builder, Handle, RuntimeFlavor};
use tokio::sync::{broadcast, mpsc};
use tokio::task::block_in_place;
use uuid::Uuid;

use crate::agents::runtime::models::validate_model;
use crate::daemon::bridge;
use crate::daemon::codex_transport::{self, CodexTransportKind};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ensure_shared_db};
use crate::daemon::index;
use crate::daemon::protocol::{
    CodexApprovalDecisionRequest, CodexApprovalRequest, CodexApprovalRequestedPayload,
    CodexRunListResponse, CodexRunRequest, CodexRunSnapshot, CodexRunStatus, CodexSteerRequest,
    StreamEvent,
};
use crate::daemon::service as daemon_service;
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as session_service;
use crate::session::types::ManagedAgentRef;
use crate::workspace::utc_now;

use super::active_runs::{ActiveRun, ActiveRuns, CodexControlMessage};
use super::effort::validate_codex_effort;
use super::events::codex_event;
use super::worker::CodexRunWorker;

#[derive(Clone)]
pub struct CodexControllerHandle {
    state: Arc<CodexControllerState>,
}

struct CodexControllerState {
    sender: broadcast::Sender<StreamEvent>,
    db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
    runtime: Option<Handle>,
    active_runs: ActiveRuns,
    sandboxed: bool,
}

impl CodexControllerHandle {
    /// Create a daemon-owned Codex controller.
    ///
    /// `sandboxed` is the daemon's sandbox-mode flag. Transport selection is
    /// re-evaluated on every [`Self::current_transport_kind`] call so runs
    /// pick up a bridge endpoint the moment `harness bridge start`
    /// publishes it, without having to restart the daemon.
    #[must_use]
    pub fn new(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        sandboxed: bool,
    ) -> Self {
        Self::new_with_async_db(sender, db, Arc::new(OnceLock::new()), sandboxed)
    }

    #[must_use]
    pub(crate) fn new_with_async_db(
        sender: broadcast::Sender<StreamEvent>,
        db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
        async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
        sandboxed: bool,
    ) -> Self {
        Self {
            state: Arc::new(CodexControllerState {
                sender,
                db,
                async_db,
                runtime: Handle::try_current().ok(),
                active_runs: ActiveRuns::default(),
                sandboxed,
            }),
        }
    }

    /// Resolve the transport to use for a new run right now. Consults the
    /// env, any running unified host bridge, and the sandbox default in that
    /// order (see [`codex_transport::codex_transport_from_env`]).
    #[must_use]
    pub fn current_transport_kind(&self) -> CodexTransportKind {
        codex_transport::codex_transport_from_env(self.state.sandboxed)
    }

    /// When the resolved transport is WebSocket, verify the endpoint is ready
    /// before queueing the run.
    /// Returns `CODEX001` immediately when the probe fails so the HTTP layer
    /// surfaces 503 in the POST response rather than failing asynchronously
    /// in the worker.
    #[expect(
        clippy::cognitive_complexity,
        reason = "preflight merges sandbox capability checks with live endpoint probing"
    )]
    fn preflight_websocket_probe(&self, session_id: &str) -> Result<(), CliError> {
        if self.state.sandboxed && var("HARNESS_CODEX_WS_URL").ok().is_none() {
            let Some(capability) = bridge::running_codex_capability()? else {
                tracing::warn!(
                    session_id,
                    "codex run preflight blocked because the host bridge capability is unavailable"
                );
                state::append_event_best_effort(
                    "warn",
                    &format!(
                        "codex run preflight blocked for session {session_id}: host bridge capability is unavailable"
                    ),
                );
                return Err(CliErrorKind::sandbox_feature_disabled(
                    bridge::BridgeCapability::Codex.sandbox_feature(),
                )
                .into());
            };
            if !capability.healthy {
                let endpoint = capability
                    .endpoint
                    .unwrap_or_else(|| codex_transport::DEFAULT_CODEX_WS_ENDPOINT.to_string());
                tracing::warn!(
                    session_id,
                    %endpoint,
                    "codex run preflight blocked because the host bridge capability is unhealthy"
                );
                state::append_event_best_effort(
                    "warn",
                    &format!(
                        "codex run preflight failed for session {session_id}: host bridge capability is unhealthy at {endpoint}"
                    ),
                );
                return Err(CliErrorKind::codex_server_unavailable(endpoint).into());
            }
        }
        let transport = self.current_transport_kind();
        let Some(endpoint) = transport.endpoint() else {
            return Ok(());
        };
        if let Err(reason) = bridge::probe_codex_readiness(endpoint, Duration::from_secs(1)) {
            tracing::warn!(
                session_id,
                %endpoint,
                %reason,
                "codex run preflight failed"
            );
            state::append_event_best_effort(
                "warn",
                &format!(
                    "codex run preflight failed for session {session_id} at {endpoint}: {reason}"
                ),
            );
            return Err(CliErrorKind::codex_server_unavailable(endpoint.to_string()).into());
        }
        Ok(())
    }

    /// Start a Codex run for a Harness session.
    ///
    /// # Errors
    /// Returns [`CliError`] when the session cannot be resolved or the snapshot
    /// cannot be persisted.
    #[expect(
        clippy::cognitive_complexity,
        reason = "queueing path builds a full persisted snapshot before worker handoff"
    )]
    pub fn start_run(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        let prompt = request.prompt.trim();
        if prompt.is_empty() {
            return Err(CliErrorKind::workflow_parse("codex prompt cannot be empty").into());
        }

        let requested_model = request.model.as_deref().filter(|value| !value.is_empty());
        if let Some(model) = requested_model
            && !request.allow_custom_model
        {
            validate_model("codex", model).map_err(|valid| {
                let detail = if valid.is_empty() {
                    "no codex model catalog available".to_string()
                } else {
                    format!("valid models: {}", valid.join(", "))
                };
                CliError::from(CliErrorKind::workflow_parse(format!(
                    "model '{model}' is not valid for runtime 'codex': {detail}"
                )))
            })?;
        }

        if let Some(effort) = request.effort.as_deref().filter(|value| !value.is_empty())
            && !request.allow_custom_model
        {
            validate_codex_effort(requested_model, effort)?;
        }

        self.preflight_websocket_probe(session_id)?;

        let project_dir = self.project_dir_for_session(session_id)?;
        let run_id = format!("codex-{}", Uuid::new_v4());
        let display_name = request.name.clone().unwrap_or_else(|| "Codex".to_string());
        let session_agent_id =
            self.register_orchestration_agent(session_id, &run_id, request, &display_name)?;
        let now = utc_now();
        let snapshot = CodexRunSnapshot {
            run_id,
            session_id: session_id.to_string(),
            session_agent_id: Some(session_agent_id),
            display_name: Some(display_name),
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
            resolved_approvals: Vec::new(),
            events: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
            model: request.model.clone(),
            effort: request.effort.clone(),
        };
        self.save_and_broadcast(&snapshot)?;
        tracing::info!(
            session_id,
            run_id = %snapshot.run_id,
            mode = ?snapshot.mode,
            "queued codex run"
        );
        state::append_event_best_effort(
            "info",
            &format!(
                "queued codex run {} for session {}",
                snapshot.run_id, snapshot.session_id
            ),
        );

        let (control_tx, control_rx) = mpsc::unbounded_channel();
        self.state
            .active_runs
            .insert(snapshot.run_id.clone(), control_tx)?;

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
        let session_id_owned = session_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            Ok(CodexRunListResponse {
                runs: async_db.list_codex_runs(&session_id_owned).await?,
            })
        }) {
            return result;
        }
        let db = self.db()?;
        let runs = lock_db(&db)?.list_codex_runs(session_id)?;
        Ok(CodexRunListResponse { runs })
    }

    /// Load one Codex run snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on database failures or when the run is missing.
    pub fn run(&self, run_id: &str) -> Result<CodexRunSnapshot, CliError> {
        let run_id_owned = run_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            async_db.codex_run(&run_id_owned).await?.ok_or_else(|| {
                CliErrorKind::session_not_active(format!("codex run '{run_id_owned}' not found"))
                    .into()
            })
        }) {
            return result;
        }
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
        if let Ok(active) = self.active_run(run_id) {
            active
                .control_tx
                .send(CodexControlMessage::Steer {
                    prompt: prompt.to_string(),
                })
                .map_err(|error| {
                    CliErrorKind::workflow_io(format!("queue codex steer: {error}"))
                })?;
            return self.run(run_id);
        }

        self.start_follow_up_turn(run_id, prompt)
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
        self.state.active_runs.get(run_id)
    }

    fn project_dir_for_session(&self, session_id: &str) -> Result<String, CliError> {
        let session_id_owned = session_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            Ok(async_db
                .resolve_session(&session_id_owned)
                .await?
                .map(|resolved| {
                    preferred_codex_project_dir(
                        &resolved.state.worktree_path,
                        resolved.project.project_dir.as_deref(),
                        resolved.project.repository_root.as_deref(),
                        &resolved.project.context_root,
                    )
                }))
        }) && let Some(project_dir) = result?
        {
            return Ok(project_dir);
        }
        let db = self.db()?;
        let guard = lock_db(&db)?;
        if let Some(project_dir) = guard.project_dir_for_session(session_id)? {
            return Ok(project_dir);
        }
        drop(guard);

        let resolved = index::resolve_session(session_id)?;
        Ok(preferred_codex_project_dir(
            &resolved.state.worktree_path,
            resolved.project.project_dir.as_deref(),
            resolved.project.repository_root.as_deref(),
            &resolved.project.context_root,
        ))
    }

    fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        ensure_shared_db(&self.state.db)
    }

    pub(super) fn remove_active_run(&self, run_id: &str) {
        self.state.active_runs.remove(run_id);
    }

    pub(super) fn save_and_broadcast(&self, snapshot: &CodexRunSnapshot) -> Result<(), CliError> {
        let persisted = snapshot.clone();
        if let Some(result) = self
            .run_with_async_db(|async_db| async move { async_db.save_codex_run(&persisted).await })
        {
            result?;
        } else {
            let db = self.db()?;
            lock_db(&db)?.save_codex_run(snapshot)?;
        }
        self.broadcast("codex_run_updated", snapshot, snapshot);
        Ok(())
    }

    fn register_orchestration_agent(
        &self,
        session_id: &str,
        run_id: &str,
        request: &CodexRunRequest,
        display_name: &str,
    ) -> Result<String, CliError> {
        let managed_agent = ManagedAgentRef::codex(run_id);
        let runtime_name = "codex";
        let session_id_owned = session_id.to_string();
        let display_name_owned = display_name.to_string();
        let managed_agent_async = managed_agent.clone();
        let request_async = request.clone();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            let now = utc_now();
            let joined_agent_id = async_db
                .update_session_state_immediate(&session_id_owned, |state| {
                    let joined_role = session_service::resolve_join_role(
                        state,
                        request_async.role,
                        request_async.fallback_role,
                    )?;
                    session_service::apply_join_session(
                        state,
                        &display_name_owned,
                        runtime_name,
                        joined_role,
                        &request_async.capabilities,
                        None,
                        &now,
                        request_async.persona.as_deref(),
                        Some(managed_agent_async),
                    )
                    .map(|agent_id| (agent_id, joined_role))
                })
                .await?;
            async_db
                .append_log_entry(&daemon_service::build_log_entry(
                    &session_id_owned,
                    session_service::log_agent_joined(
                        &joined_agent_id.0,
                        joined_agent_id.1,
                        runtime_name,
                    ),
                    None,
                    None,
                ))
                .await?;
            async_db.bump_change(&session_id_owned).await?;
            async_db.bump_change("global").await?;
            Ok(joined_agent_id.0)
        }) {
            return result;
        }

        let db = self.db()?;
        let db = lock_db(&db)?;
        let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
            return Err(daemon_service::session_not_found(session_id));
        };
        let now = utc_now();
        let joined_role =
            session_service::resolve_join_role(&state, request.role, request.fallback_role)?;
        let agent_id = session_service::apply_join_session(
            &mut state,
            display_name,
            runtime_name,
            joined_role,
            &request.capabilities,
            None,
            &now,
            request.persona.as_deref(),
            Some(managed_agent),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| daemon_service::session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&daemon_service::build_log_entry(
            session_id,
            session_service::log_agent_joined(&agent_id, joined_role, runtime_name),
            None,
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        Ok(agent_id)
    }

    fn start_follow_up_turn(
        &self,
        run_id: &str,
        prompt: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        let mut snapshot = self.run(run_id)?;
        if snapshot.thread_id.is_none() {
            return Err(CliErrorKind::session_not_active(format!(
                "codex agent '{run_id}' has no thread to resume"
            ))
            .into());
        }
        if snapshot.status.is_active() {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "codex agent '{run_id}' already has an active turn"
            ))
            .into());
        }

        self.preflight_websocket_probe(&snapshot.session_id)?;
        snapshot.prompt = prompt.to_string();
        snapshot.turn_id = None;
        snapshot.status = CodexRunStatus::Queued;
        snapshot.latest_summary = Some("Queued follow-up turn".to_string());
        snapshot.final_message = None;
        snapshot.error = None;
        snapshot.pending_approvals.clear();
        snapshot.updated_at = utc_now();
        self.save_and_broadcast(&snapshot)?;

        let (control_tx, control_rx) = mpsc::unbounded_channel();
        self.state
            .active_runs
            .insert(snapshot.run_id.clone(), control_tx)?;
        let worker = CodexRunWorker::new(self.clone(), snapshot.clone(), control_rx);
        tokio::spawn(async move {
            worker.run().await;
        });
        Ok(snapshot)
    }

    pub(super) fn broadcast_approval(
        &self,
        snapshot: &CodexRunSnapshot,
        approval: &CodexApprovalRequest,
    ) {
        let payload = CodexApprovalRequestedPayload {
            run: snapshot.clone(),
            approval: approval.clone(),
        };
        self.broadcast("codex_approval_requested", snapshot, &payload);
    }

    fn broadcast<T: Serialize>(&self, event: &str, snapshot: &CodexRunSnapshot, payload: &T) {
        let Some(stream_event) = codex_event(event, snapshot, payload) else {
            return;
        };
        let _ = self.state.sender.send(stream_event);
    }

    fn run_with_async_db<T, F, Fut>(&self, task: F) -> Option<Result<T, CliError>>
    where
        F: FnOnce(Arc<AsyncDaemonDb>) -> Fut,
        Fut: Future<Output = Result<T, CliError>> + Send + 'static,
        T: Send + 'static,
    {
        let async_db = self.state.async_db.get()?.clone();
        let runtime = self.state.runtime.clone()?;
        let future = task(async_db);
        Some(match Handle::try_current() {
            Ok(current) => match current.runtime_flavor() {
                RuntimeFlavor::MultiThread => block_in_place(|| runtime.block_on(future)),
                RuntimeFlavor::CurrentThread => thread::spawn(move || {
                    Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .map_err(|error| {
                            CliError::from(CliErrorKind::workflow_io(format!(
                                "build async codex bridge runtime: {error}"
                            )))
                        })?
                        .block_on(future)
                })
                .join()
                .map_err(|_| {
                    CliError::from(CliErrorKind::workflow_io("join async codex bridge thread"))
                })
                .and_then(identity),
                _ => runtime.block_on(future),
            },
            Err(_) => runtime.block_on(future),
        })
    }
}

pub(super) fn preferred_codex_project_dir(
    worktree_path: &Path,
    project_dir: Option<&Path>,
    repository_root: Option<&Path>,
    context_root: &Path,
) -> String {
    let path = if worktree_path.as_os_str().is_empty() {
        project_dir.or(repository_root).unwrap_or(context_root)
    } else {
        worktree_path
    };
    path.display().to_string()
}

fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}
