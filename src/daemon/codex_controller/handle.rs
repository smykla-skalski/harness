use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use serde_json::{Value, json};
use tokio::runtime::Handle;
use tokio::sync::{broadcast, mpsc};
use uuid::Uuid;

use crate::agents::runtime::models::validate_model;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{
    CodexAgentInspectResponse, CodexRunEvent, CodexRunListResponse, CodexRunRequest,
    CodexRunSnapshot, CodexRunStatus, CodexTranscriptResponse, StreamEvent,
};
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::ManagedAgentRef;
use crate::workspace::utc_now;

use super::active_runs::ActiveRuns;
use super::effort::validate_codex_effort;
use super::transcript::codex_transcript_entries;
use super::worker::CodexRunWorker;

#[derive(Clone)]
pub struct CodexControllerHandle {
    pub(super) state: Arc<CodexControllerState>,
}

pub(super) struct CodexControllerState {
    pub(super) sender: broadcast::Sender<StreamEvent>,
    pub(super) db: Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    pub(super) async_db: Arc<OnceLock<Arc<AsyncDaemonDb>>>,
    pub(super) runtime: Option<Handle>,
    pub(super) active_runs: ActiveRuns,
    pub(super) sandboxed: bool,
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
        let prompt = validate_run_request(request)?;
        self.preflight_websocket_probe(session_id)?;

        let project_dir = self.project_dir_for_session(session_id)?;
        let run_id = format!("codex-{}", Uuid::new_v4());
        let display_name = request.name.clone().unwrap_or_else(|| "Codex".to_string());
        let session_agent_id =
            self.register_orchestration_agent(session_id, &run_id, request, &display_name)?;
        let snapshot = queued_run_snapshot(
            session_id,
            request,
            run_id,
            project_dir,
            prompt,
            session_agent_id,
            display_name,
        );
        if let Err(error) = self.save_and_broadcast(&snapshot) {
            self.rollback_orchestration_agent_registration(
                session_id,
                snapshot.session_agent_id.as_deref(),
                &ManagedAgentRef::codex(snapshot.run_id.as_str()),
            );
            return Err(error);
        }
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
        if let Err(error) = self
            .state
            .active_runs
            .insert(snapshot.run_id.clone(), control_tx)
        {
            let failed = active_run_attach_failure(snapshot, &error);
            let _ = self.save_and_broadcast(&failed);
            let _ = self.sync_orchestration_status_for_run(&failed);
            return Err(error);
        }

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
            let mut response = result?;
            response.runs = self.reconcile_stale_runs(response.runs)?;
            return Ok(response);
        }
        let db = self.db()?;
        let runs = lock_db(&db)?.list_codex_runs(session_id)?;
        Ok(CodexRunListResponse {
            runs: self.reconcile_stale_runs(runs)?,
        })
    }

    /// Load one Codex run snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on database failures or when the run is missing.
    pub fn run(&self, run_id: &str) -> Result<CodexRunSnapshot, CliError> {
        let run = self.load_run(run_id)?;
        self.reconcile_run(run)
    }

    pub(crate) fn session_id_for_run(&self, run_id: &str) -> Result<String, CliError> {
        Ok(self.load_run(run_id)?.session_id)
    }

    /// Inspect managed Codex agents, scoped to a session when supplied.
    ///
    /// # Errors
    /// Returns [`CliError`] on database failures.
    pub fn inspect(&self, session_id: Option<&str>) -> Result<CodexAgentInspectResponse, CliError> {
        let runs = match session_id {
            Some(session_id) => self.list_runs(session_id)?.runs,
            None => self.list_active_runs()?,
        };
        Ok(CodexAgentInspectResponse {
            agents: runs.iter().map(|run| self.inspect_snapshot(run)).collect(),
            daemon_perceived_now: utc_now(),
            available: true,
            issue_message: None,
        })
    }

    /// Build transcript entries for managed Codex agents in a session.
    ///
    /// # Errors
    /// Returns [`CliError`] on database failures.
    pub fn transcript(&self, session_id: &str) -> Result<CodexTranscriptResponse, CliError> {
        let mut entries = Vec::new();
        for run in self.list_runs(session_id)?.runs {
            entries.extend(codex_transcript_entries(&run));
        }
        entries.sort_by(|left, right| {
            right
                .recorded_at
                .cmp(&left.recorded_at)
                .then_with(|| right.entry_id.cmp(&left.entry_id))
        });
        Ok(CodexTranscriptResponse { entries })
    }
}

fn validate_run_request(request: &CodexRunRequest) -> Result<&str, CliError> {
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
    Ok(prompt)
}

fn queued_run_snapshot(
    session_id: &str,
    request: &CodexRunRequest,
    run_id: String,
    project_dir: String,
    prompt: &str,
    session_agent_id: String,
    display_name: String,
) -> CodexRunSnapshot {
    let now = utc_now();
    CodexRunSnapshot {
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
        model: non_empty_owned(request.model.as_deref()),
        effort: non_empty_owned(request.effort.as_deref()),
    }
}

fn non_empty_owned(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn active_run_attach_failure(mut failed: CodexRunSnapshot, error: &CliError) -> CodexRunSnapshot {
    failed.status = CodexRunStatus::Failed;
    failed.latest_summary = Some("Codex worker could not attach to daemon".to_string());
    failed.error = Some(error.to_string());
    failed.updated_at = utc_now();
    let payload = json!({
        "runId": failed.run_id.clone(),
        "status": "failed",
        "reason": "active run registry failed",
        "error": failed.error.clone(),
    });
    record_snapshot_event(
        &mut failed,
        "agent/reconciled",
        "Codex worker could not attach to daemon".to_string(),
        &payload,
    );
    failed
}

pub(super) fn record_snapshot_event(
    snapshot: &mut CodexRunSnapshot,
    kind: &str,
    summary: String,
    payload: &Value,
) {
    let sequence = u64::try_from(snapshot.events.len())
        .unwrap_or(u64::MAX - 1)
        .saturating_add(1);
    snapshot.events.push(CodexRunEvent {
        event_id: format!("{}-{sequence}", snapshot.run_id),
        sequence,
        recorded_at: utc_now(),
        kind: kind.to_string(),
        summary,
        thread_id: event_string(payload, &["/thread/id", "/threadId"])
            .or_else(|| snapshot.thread_id.clone()),
        turn_id: event_string(payload, &["/turn/id", "/turnId"])
            .or_else(|| snapshot.turn_id.clone()),
        item_id: event_string(payload, &["/item/id", "/itemId"]),
        payload: payload.clone(),
    });
}

fn event_string(payload: &Value, paths: &[&str]) -> Option<String> {
    paths
        .iter()
        .find_map(|path| payload.pointer(path).and_then(Value::as_str))
        .map(ToString::to_string)
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

pub(super) fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::protocol::CodexRunMode;
    use crate::session::types::SessionRole;

    #[test]
    fn queued_run_snapshot_normalizes_blank_model_and_effort() {
        let request = CodexRunRequest {
            actor: None,
            prompt: "investigate".to_string(),
            mode: CodexRunMode::Report,
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            persona: None,
            resume_thread_id: None,
            model: Some("  ".to_string()),
            effort: Some(" high ".to_string()),
            allow_custom_model: false,
        };

        let snapshot = queued_run_snapshot(
            "session-1",
            &request,
            "run-1".to_string(),
            "/tmp/project".to_string(),
            "investigate",
            "agent-1".to_string(),
            "Codex".to_string(),
        );

        assert_eq!(snapshot.model, None);
        assert_eq!(snapshot.effort.as_deref(), Some("high"));
    }
}
