use std::collections::HashMap;
use std::convert::identity;
use std::env::var;
use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tokio::runtime::{Builder, Handle, RuntimeFlavor};
use tokio::sync::{broadcast, mpsc};
use tokio::task::block_in_place;
use uuid::Uuid;

use crate::daemon::bridge;
use crate::daemon::codex_transport::{self, CodexTransportKind};
use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ensure_shared_db};
use crate::daemon::index;
use crate::daemon::protocol::{
    CodexApprovalDecision, CodexApprovalDecisionRequest, CodexApprovalRequest,
    CodexApprovalRequestedPayload, CodexRunListResponse, CodexRunRequest, CodexRunSnapshot,
    CodexRunStatus, CodexSteerRequest, StreamEvent,
};
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

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
    active_runs: Arc<Mutex<HashMap<String, ActiveRun>>>,
    sandboxed: bool,
}

#[derive(Clone)]
struct ActiveRun {
    control_tx: mpsc::UnboundedSender<CodexControlMessage>,
}

#[derive(Debug)]
pub(super) enum CodexControlMessage {
    Approval {
        approval_id: String,
        decision: CodexApprovalDecision,
    },
    Steer {
        prompt: String,
    },
    Interrupt,
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
                active_runs: Arc::default(),
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

        self.preflight_websocket_probe(session_id)?;

        let project_dir = self.project_dir_for_session(session_id)?;
        let now = utc_now();
        let snapshot = CodexRunSnapshot {
            run_id: format!("codex-{}", Uuid::new_v4()),
            session_id: session_id.to_string(),
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
            created_at: now.clone(),
            updated_at: now,
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
        self.active_runs()?
            .insert(snapshot.run_id.clone(), ActiveRun { control_tx });

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
        let active = self.active_run(run_id)?;
        active
            .control_tx
            .send(CodexControlMessage::Steer {
                prompt: prompt.to_string(),
            })
            .map_err(|error| CliErrorKind::workflow_io(format!("queue codex steer: {error}")))?;
        self.run(run_id)
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
        self.active_runs()?.get(run_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!("codex run '{run_id}' is not active")).into()
        })
    }

    fn project_dir_for_session(&self, session_id: &str) -> Result<String, CliError> {
        let session_id_owned = session_id.to_string();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            Ok(async_db
                .resolve_session(&session_id_owned)
                .await?
                .and_then(|resolved| {
                    resolved
                        .project
                        .project_dir
                        .or(resolved.project.repository_root)
                        .map(|path| path.display().to_string())
                        .or_else(|| Some(resolved.project.context_root.display().to_string()))
                }))
        }) {
            if let Some(project_dir) = result? {
                return Ok(project_dir);
            }
        }
        let db = self.db()?;
        let guard = lock_db(&db)?;
        if let Some(project_dir) = guard.project_dir_for_session(session_id)? {
            return Ok(project_dir);
        }
        drop(guard);

        let resolved = index::resolve_session(session_id)?;
        let fallback = resolved
            .project
            .project_dir
            .or(resolved.project.repository_root)
            .unwrap_or(resolved.project.context_root);
        Ok(fallback.display().to_string())
    }

    fn db(&self) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
        ensure_shared_db(&self.state.db)
    }

    fn active_runs(&self) -> Result<MutexGuard<'_, HashMap<String, ActiveRun>>, CliError> {
        self.state.active_runs.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("codex active run lock poisoned: {error}")).into()
        })
    }

    pub(super) fn remove_active_run(&self, run_id: &str) {
        let Ok(mut active_runs) = self.state.active_runs.lock() else {
            return;
        };
        active_runs.remove(run_id);
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
        let Some(payload) = codex_event_payload(event, payload) else {
            return;
        };
        let event = StreamEvent {
            event: event.to_string(),
            recorded_at: utc_now(),
            session_id: Some(snapshot.session_id.clone()),
            payload,
        };
        let _ = self.state.sender.send(event);
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

fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn codex_event_payload<T: Serialize>(event: &str, payload: &T) -> Option<Value> {
    match serde_json::to_value(payload) {
        Ok(payload) => Some(payload),
        Err(error) => {
            tracing::warn!(%error, event, "failed to serialize codex controller event");
            None
        }
    }
}
