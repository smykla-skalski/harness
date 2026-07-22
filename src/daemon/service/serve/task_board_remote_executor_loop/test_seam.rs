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
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

static START_CALLS: AtomicUsize = AtomicUsize::new(0);
static PROVISION_CALLS: AtomicUsize = AtomicUsize::new(0);

static RUNTIME_SEAM: OnceLock<Mutex<Option<Arc<AsyncMutex<RuntimeSeamState>>>>> =
    OnceLock::new();
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

/// Records one fresh external Codex Start attempt (`start_codex_run`).
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
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    action: &PreparedRemoteWorkerAction,
    workspace: &Path,
) -> Result<Option<CodexRunSnapshot>, CliError> {
    let seam = runtime_seam_slot()
        .lock()
        .expect("lock deterministic runtime seam slot")
        .clone();
    let Some(seam) = seam else {
        return Ok(None);
    };
    let outcome = record_runtime_call(&seam, offer, identity, action, workspace).await?;
    let snapshot = runtime_snapshot(db, offer, identity, workspace, &outcome).await?;
    db.save_codex_run(&snapshot).await?;
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
        RuntimeSeamAction::Probe { .. } => {
            RuntimeSeamOutcome::Probe {
                final_message: state.completed_runs.get(&identity.run_id).cloned(),
            }
        }
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
    if state.completed_runs.get(&identity.run_id).map(String::as_str) == Some(final_message) {
        state.completed_runs.remove(&identity.run_id);
    }
}

async fn runtime_snapshot(
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
    outcome: &RuntimeSeamOutcome,
) -> Result<CodexRunSnapshot, CliError> {
    match outcome {
        RuntimeSeamOutcome::Start => deterministic_start_snapshot(offer, identity, workspace),
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
            Ok(snapshot)
        }
    }
}

impl RuntimeSeamOutcome {
    fn armed_final_message(&self) -> Option<&str> {
        match self {
            Self::Start | Self::Probe { final_message: None } => None,
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
) -> Result<CodexRunSnapshot, CliError> {
    let request = offer.launch.codex_request();
    let observed_at = utc_now();
    Ok(CodexRunSnapshot {
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
    })
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
