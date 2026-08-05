//! Test-only counters proving the production executor loop performs at most one
//! fresh external Start and one session provisioning per generation. Deterministic
//! run persistence upserts by `run_id`, so a duplicate Start cannot be seen by
//! counting `codex_runs` rows; these counters observe the calls directly.
//!
//! Nextest isolates each test in its own process, so plain global atomics are
//! private to a single test. Call [`reset_counters`] after fixture setup and
//! before the reconcile under test to discard provisioning done while staging.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use super::RemoteWorkerIdentity;
use super::runtime::PreparedRemoteWorkerAction;
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus, TaskBoardRemoteExecutorRun};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};
use crate::task_board::remote_wire::wire::RemoteOfferRequest;
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

static START_CALLS: AtomicUsize = AtomicUsize::new(0);
static PROVISION_CALLS: AtomicUsize = AtomicUsize::new(0);

static RUNTIME_SEAM: OnceLock<Mutex<Option<Arc<AsyncMutex<RuntimeSeamState>>>>> = OnceLock::new();
static RUNTIME_SEAM_SERIAL: OnceLock<Arc<AsyncMutex<()>>> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum RuntimeSeamAction {
    Start { permit_sha256: String },
    Probe { permit_sha256: Option<String> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RuntimeSeamCall {
    pub(super) offer: RemoteOfferRequest,
    pub(super) identity: RemoteWorkerIdentity,
    pub(super) action: RuntimeSeamAction,
    pub(super) workspace: PathBuf,
}

struct RuntimeSeamState {
    calls: Vec<RuntimeSeamCall>,
    started_runs: BTreeSet<String>,
    completed_runs: BTreeMap<String, String>,
}

enum RuntimeSeamOutcome {
    Start,
    Probe { final_message: Option<String> },
}

pub(crate) struct RuntimeSeamScope {
    seam: Arc<AsyncMutex<RuntimeSeamState>>,
    _serial: OwnedMutexGuard<()>,
}

/// Records one fresh external runtime Start attempt.
pub(super) fn record_start() {
    START_CALLS.fetch_add(1, Ordering::SeqCst);
}

/// Records one deterministic executor session provisioning (a fresh worktree
/// create in `ensure_remote_session`).
pub(super) fn record_provision() {
    PROVISION_CALLS.fetch_add(1, Ordering::SeqCst);
}

pub(super) fn start_calls() -> usize {
    START_CALLS.load(Ordering::SeqCst)
}

pub(super) fn provision_calls() -> usize {
    PROVISION_CALLS.load(Ordering::SeqCst)
}

pub(super) fn reset_counters() {
    START_CALLS.store(0, Ordering::SeqCst);
    PROVISION_CALLS.store(0, Ordering::SeqCst);
}

pub(crate) async fn install_deterministic_runtime_seam() -> RuntimeSeamScope {
    let serial = runtime_seam_serial().clone().lock_owned().await;
    let seam = Arc::new(AsyncMutex::new(RuntimeSeamState {
        calls: Vec::new(),
        started_runs: BTreeSet::new(),
        completed_runs: BTreeMap::new(),
    }));
    let mut installed = runtime_seam_slot()
        .lock()
        .expect("lock deterministic runtime seam slot");
    assert!(installed.is_none(), "runtime seam scope must be serialized");
    *installed = Some(seam.clone());
    RuntimeSeamScope {
        seam,
        _serial: serial,
    }
}

pub(super) async fn execute_runtime_seam(
    db: &AsyncDaemonDbHandle,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    action: &PreparedRemoteWorkerAction,
    workspace: &Path,
) -> Result<Option<TaskBoardRemoteExecutorRun>, CliError> {
    let seam = runtime_seam_slot()
        .lock()
        .expect("lock deterministic runtime seam slot")
        .clone();
    let Some(seam) = seam else {
        return Ok(None);
    };
    let outcome = record_runtime_call(&seam, offer, identity, action, workspace).await?;
    let snapshot = runtime_snapshot(db, offer, identity, workspace, &outcome).await?;
    if let Some(final_message) = outcome.armed_final_message() {
        disarm_completed_probe(&seam, identity, final_message).await;
    }
    Ok(Some(snapshot))
}

pub(super) fn runtime_seam_installed() -> bool {
    runtime_seam_slot()
        .lock()
        .expect("lock deterministic runtime seam slot")
        .is_some()
}

impl RuntimeSeamScope {
    pub(crate) async fn start_count(&self) -> usize {
        self.seam.lock().await.started_runs.len()
    }

    pub(super) async fn calls(&self) -> Vec<RuntimeSeamCall> {
        self.seam.lock().await.calls.clone()
    }

    pub(crate) async fn arm_completed(
        &self,
        run_id: &str,
        final_message: String,
    ) -> Result<(), CliError> {
        let mut state = self.seam.lock().await;
        if !state.started_runs.contains(run_id) {
            return Err(invalid_transition(
                "deterministic runtime seam can arm only its started run",
            ));
        }
        if state.completed_runs.contains_key(run_id) {
            return Err(invalid_transition(
                "deterministic runtime seam already armed this run",
            ));
        }
        state.completed_runs.insert(run_id.into(), final_message);
        Ok(())
    }
}

impl Drop for RuntimeSeamScope {
    fn drop(&mut self) {
        let mut installed = runtime_seam_slot()
            .lock()
            .expect("lock deterministic runtime seam slot");
        *installed = None;
    }
}

async fn record_runtime_call(
    seam: &AsyncMutex<RuntimeSeamState>,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    action: &PreparedRemoteWorkerAction,
    workspace: &Path,
) -> Result<RuntimeSeamOutcome, CliError> {
    let action = match action {
        PreparedRemoteWorkerAction::Start(permit) => RuntimeSeamAction::Start {
            permit_sha256: permit.sha256.clone(),
        },
        PreparedRemoteWorkerAction::Probe(permit) => RuntimeSeamAction::Probe {
            permit_sha256: permit.as_ref().map(|permit| permit.sha256.clone()),
        },
    };
    let mut state = seam.lock().await;
    let outcome = match &action {
        RuntimeSeamAction::Start { .. } => {
            if !state.started_runs.insert(identity.run_id.clone()) {
                return Err(invalid_transition(
                    "deterministic runtime seam forbids duplicate Start for one run",
                ));
            }
            RuntimeSeamOutcome::Start
        }
        RuntimeSeamAction::Probe { .. } => RuntimeSeamOutcome::Probe {
            final_message: state.completed_runs.get(&identity.run_id).cloned(),
        },
    };
    state.calls.push(RuntimeSeamCall {
        offer: offer.clone(),
        identity: identity.clone(),
        action,
        workspace: workspace.into(),
    });
    Ok(outcome)
}

async fn disarm_completed_probe(
    seam: &AsyncMutex<RuntimeSeamState>,
    identity: &RemoteWorkerIdentity,
    final_message: &str,
) {
    let mut state = seam.lock().await;
    if state
        .completed_runs
        .get(&identity.run_id)
        .map(String::as_str)
        == Some(final_message)
    {
        state.completed_runs.remove(&identity.run_id);
    }
}

async fn runtime_snapshot(
    db: &AsyncDaemonDbHandle,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
    outcome: &RuntimeSeamOutcome,
) -> Result<TaskBoardRemoteExecutorRun, CliError> {
    if offer.launch.runtime == "openrouter" {
        persist_agent_turn_snapshot(db, offer, identity, workspace, outcome).await?;
        return db
            .task_board_remote_executor_run(offer, &identity.run_id)
            .await?
            .ok_or_else(|| invalid_transition("deterministic runtime seam lost agent turn run"));
    }
    match outcome {
        RuntimeSeamOutcome::Start => {
            let snapshot = deterministic_start_snapshot(offer, identity, workspace);
            db.save_codex_run(&snapshot).await?;
            Ok(TaskBoardRemoteExecutorRun::from(snapshot))
        }
        RuntimeSeamOutcome::Probe { final_message } => {
            let mut snapshot = db
                .codex_run(&identity.run_id)
                .await?
                .ok_or_else(|| invalid_transition("deterministic runtime seam Probe has no run"))?;
            if let Some(final_message) = final_message.as_ref() {
                snapshot.status = CodexRunStatus::Completed;
                snapshot.final_message = Some(final_message.clone());
                snapshot.error = None;
                snapshot.updated_at = utc_now();
            }
            db.save_codex_run(&snapshot).await?;
            Ok(TaskBoardRemoteExecutorRun::from(snapshot))
        }
    }
}

async fn persist_agent_turn_snapshot(
    db: &AsyncDaemonDbHandle,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
    outcome: &RuntimeSeamOutcome,
) -> Result<(), CliError> {
    let now = utc_now();
    let mut snapshot = db
        .agent_turn_run(&identity.run_id)
        .await?
        .unwrap_or_else(|| AgentTurnRunSnapshot {
            run_id: identity.run_id.clone(),
            session_id: Some(identity.session_id.clone()),
            task_id: offer.launch.task_id.clone(),
            board_item_id: Some(offer.launch.board_item_id.clone()),
            workflow_execution_id: Some(offer.launch.workflow_execution_id.clone()),
            project_dir: Some(workspace.to_string_lossy().into_owned()),
            runtime_turn_id: Some(format!("acp:{}", identity.run_id)),
            requested_runtime: "openrouter".into(),
            actual_runtime: Some("openrouter".into()),
            requested_model: offer.launch.model.clone(),
            actual_model: None,
            status: AgentTurnRunStatus::Running,
            source_revision: None,
            report: None,
            stop_reason: None,
            error: None,
            created_at: now.clone(),
            updated_at: now.clone(),
        });
    if let RuntimeSeamOutcome::Probe {
        final_message: Some(message),
    } = outcome
    {
        snapshot.status = AgentTurnRunStatus::Completed;
        snapshot.report = Some(message.clone());
        snapshot.updated_at = now;
    }
    db.save_agent_turn_run(&snapshot).await
}

impl RuntimeSeamOutcome {
    fn armed_final_message(&self) -> Option<&str> {
        match self {
            Self::Start
            | Self::Probe {
                final_message: None,
            } => None,
            Self::Probe {
                final_message: Some(message),
            } => Some(message),
        }
    }
}

fn deterministic_start_snapshot(
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> CodexRunSnapshot {
    let request = offer.launch.run_request();
    let observed_at = utc_now();
    CodexRunSnapshot {
        run_id: identity.run_id.clone(),
        session_id: identity.session_id.clone(),
        task_id: request.task_id,
        board_item_id: request.board_item_id,
        workflow_execution_id: request.workflow_execution_id,
        session_agent_id: None,
        display_name: request.name,
        project_dir: workspace.to_string_lossy().into_owned(),
        thread_id: request.resume_thread_id,
        turn_id: None,
        mode: request.mode,
        status: CodexRunStatus::Running,
        prompt: request.prompt,
        latest_summary: None,
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: observed_at.clone(),
        updated_at: observed_at,
        model: request.model,
        effort: request.effort,
    }
}

fn runtime_seam_slot() -> &'static Mutex<Option<Arc<AsyncMutex<RuntimeSeamState>>>> {
    RUNTIME_SEAM.get_or_init(|| Mutex::new(None))
}

fn runtime_seam_serial() -> &'static Arc<AsyncMutex<()>> {
    RUNTIME_SEAM_SERIAL.get_or_init(|| Arc::new(AsyncMutex::new(())))
}

fn invalid_transition(message: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(message.into()).into()
}
