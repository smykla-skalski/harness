//! Bounded background executor for triage escalations. Drains
//! `task_board_triage_escalations`, spawning one standalone, non-interactive
//! Codex report-mode run per claimed row -- never the interactive
//! dispatch/workflow apparatus, and never a real Harness session (see
//! `CodexControllerHandle::start_standalone_run_with_id`). Each run gets its
//! own empty, per-escalation scratch directory: combined with
//! `CodexRunMode::Report` (no workspace-write capability), the run has zero
//! repository access, matching what a pure triage judgment call needs.

use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};
use tracing::warn;

use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardTriageEscalation};
use crate::daemon::http::{DaemonHttpState, run_codex_agent_blocking};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use harness_kernel::errors::{CliError, CliErrorKind};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::{TaskBoardTriageEscalationConfig, render_triage_escalation_prompt};

const TICK_INTERVAL: Duration = Duration::from_secs(5);
const SCRATCH_DIR_NAME: &str = "triage-escalation-scratch";

pub(super) fn spawn_task_board_triage_escalation_loop(
    state: DaemonHttpState,
    config: TaskBoardTriageEscalationConfig,
    shutdown_rx: watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_task_board_triage_escalation_loop(
        state,
        config,
        shutdown_rx,
    ))
}

async fn run_task_board_triage_escalation_loop(
    state: DaemonHttpState,
    config: TaskBoardTriageEscalationConfig,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    if !config.enabled {
        return;
    }
    let Some(db) = state.async_db.get().cloned() else {
        return;
    };
    let mut ticker = interval(TICK_INTERVAL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
            _ = ticker.tick() => drain_tick(&state, &db, &config).await,
        }
    }
}

async fn drain_tick(state: &DaemonHttpState, db: &AsyncDaemonDb, config: &TaskBoardTriageEscalationConfig) {
    match db
        .sweep_stale_task_board_triage_escalations(config.timeout_seconds)
        .await
    {
        Ok(timed_out_run_ids) => {
            // Detached rather than awaited in sequence: a tick with several
            // hung processes to stop would otherwise serialize their
            // individual best-effort timeouts, delaying this tick (and, at
            // shutdown, the daemon itself) by up to N times a single stop's
            // own timeout.
            for managed_run_id in timed_out_run_ids {
                let state = state.clone();
                tokio::spawn(async move { stop_escalation_worker(&state, &managed_run_id).await });
            }
        }
        Err(error) => warn!(%error, "triage escalation timeout sweep failed"),
    }
    let running = match db.count_running_task_board_triage_escalations().await {
        Ok(count) => count,
        Err(error) => {
            warn!(%error, "triage escalation running count failed");
            return;
        }
    };
    let capacity = config.max_concurrent.saturating_sub(running);
    if capacity == 0 {
        return;
    }
    let claimed = match db.claim_pending_task_board_triage_escalations(capacity).await {
        Ok(claimed) => claimed,
        Err(error) => {
            warn!(%error, "triage escalation claim failed");
            return;
        }
    };
    for escalation in claimed {
        if let Err(error) = spawn_escalation_worker(state, db, &escalation).await {
            warn!(
                escalation_id = %escalation.escalation_id,
                item_id = %escalation.item_id,
                %error,
                "triage escalation worker spawn failed"
            );
            if let Err(fail_error) = db
                .fail_running_task_board_triage_escalation(&escalation.escalation_id, &error.to_string())
                .await
            {
                warn!(
                    escalation_id = %escalation.escalation_id,
                    %fail_error,
                    "failed to mark triage escalation failed after a spawn error"
                );
            }
        }
    }
}

/// Best-effort: a hung report-mode process that already timed out is not
/// worth failing the tick over if it cannot be reached (already exited,
/// bridge unavailable, etc.) -- the DB row is already terminal either way.
async fn stop_escalation_worker(state: &DaemonHttpState, managed_run_id: &str) {
    let run_id = managed_run_id.to_string();
    if let Err(error) =
        run_codex_agent_blocking(state, "triage escalation stop", move |controller| {
            controller.stop(&run_id)
        })
        .await
    {
        warn!(managed_run_id, %error, "failed to stop timed-out triage escalation worker");
    }
}

async fn spawn_escalation_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    escalation: &ClaimedTaskBoardTriageEscalation,
) -> Result<(), CliError> {
    let item = db.task_board_item(&escalation.item_id).await?;
    let project_dir = ensure_escalation_scratch_dir(db, &escalation.escalation_id)?;
    let prompt = render_triage_escalation_prompt(
        &item,
        &escalation.escalation_id,
        &escalation.verdict_token,
        &escalation.evidence_fingerprint,
    )?;
    let request = CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt,
        mode: CodexRunMode::Report,
        role: SessionRole::Leader,
        fallback_role: None,
        capabilities: Vec::new(),
        name: Some(format!("Triage escalation: {}", item.title)),
        persona: None,
        resume_thread_id: None,
        task_id: None,
        board_item_id: Some(escalation.item_id.clone()),
        workflow_execution_id: None,
        model: None,
        effort: None,
        allow_custom_model: false,
    };
    let run_id = escalation.managed_run_id.clone();
    run_codex_agent_blocking(state, "triage escalation start", move |controller| {
        controller
            .start_standalone_run_with_id(&project_dir, &request, run_id)
            .map(|_| ())
    })
    .await
}

/// A dedicated, empty directory per escalation under the daemon's own data
/// home, created idempotently. Never cleaned up eagerly on the happy path --
/// the executor never learns synchronously when a standalone run's worker
/// finishes, so proactive removal here could race a still-running process;
/// stale scratch directories are small, inert, and safe to leave for the
/// same lifetime as the daemon's other run artifacts.
fn ensure_escalation_scratch_dir(
    db: &AsyncDaemonDb,
    escalation_id: &str,
) -> Result<String, CliError> {
    let base = db
        .storage_path()
        .parent()
        .map_or_else(|| PathBuf::from(SCRATCH_DIR_NAME), |parent| parent.join(SCRATCH_DIR_NAME));
    let dir = base.join(sanitized_escalation_segment(escalation_id));
    fs::create_dir_all(&dir).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "create triage escalation scratch dir: {error}"
        ))
    })?;
    Ok(dir.to_string_lossy().into_owned())
}

/// `escalation_id` is our own UUID-derived id, but this stays defensive
/// against ever using an untrusted value as a path segment.
fn sanitized_escalation_segment(escalation_id: &str) -> String {
    escalation_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' {
                character
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
#[path = "task_board_triage_escalation_loop_tests.rs"]
mod tests;
