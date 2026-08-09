//! Startup recovery for direct interactive Task Board workers.

use crate::daemon::db::TaskBoardAdmissionWorkerRecovery;
use crate::daemon::db::task_board::prelude::*;
#[cfg(test)]
use crate::daemon::http::require_async_db;
use crate::daemon::http::{DaemonHttpState, run_terminal_agent_blocking};
use crate::daemon::protocol::ManagedAgentSnapshot;
use harness_daemon_managed_agents::AsyncAgentTuiStorage;
use harness_kernel::errors::CliError;

use super::{join_worker_to_workspace, recover_same_applied_worker, worker_lock_owner};

const MISSING_WORKER_RECOVERY_REASON: &str = "Managed worker was missing after daemon restart";

#[cfg(test)]
pub(crate) async fn reconcile_interactive_workers_after_restart(
    state: &DaemonHttpState,
) -> Result<(), CliError> {
    let db = require_async_db(state, "interactive task-board admission recovery")?;
    let recoveries = db.prepare_task_board_admission_worker_recoveries().await?;
    reconcile_interactive_workers(state, db, &recoveries).await
}

pub(crate) async fn reconcile_interactive_workers(
    state: &DaemonHttpState,
    db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
    recoveries: &[TaskBoardAdmissionWorkerRecovery],
) -> Result<(), CliError> {
    for recovery in recoveries {
        if !recovery.managed_worker_id.starts_with("agent-tui-") {
            continue;
        }
        let owner = worker_lock_owner(&recovery.dispatch);
        let _guard = state
            .managed_agent_mutation_locks
            .lock(&owner, &recovery.managed_worker_id)
            .await;
        reconcile_interactive_worker(state, db, recovery).await?;
    }
    Ok(())
}

async fn reconcile_interactive_worker(
    state: &DaemonHttpState,
    db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
    recovery: &TaskBoardAdmissionWorkerRecovery,
) -> Result<(), CliError> {
    if db.agent_tui(&recovery.managed_worker_id).await?.is_none()
        && db
            .reconcile_missing_task_board_admission_worker(recovery, MISSING_WORKER_RECOVERY_REASON)
            .await?
            .is_some()
    {
        return Ok(());
    }
    if db.agent_tui(&recovery.managed_worker_id).await?.is_none() {
        return Ok(());
    }
    join_worker_to_workspace(db, &recovery.dispatch, &recovery.managed_worker_id).await?;
    let worker_id = recovery.managed_worker_id.clone();
    let workspace_id = recovery.dispatch.workspace_id.clone();
    let snapshot = run_terminal_agent_blocking(state, "startup recovery", move |manager| {
        manager.recover_after_restart(&worker_id, workspace_id.as_deref())
    })
    .await?;
    let snapshot = recover_same_applied_worker(
        ManagedAgentSnapshot::Terminal(snapshot),
        &recovery.dispatch,
        &recovery.managed_worker_id,
    )?;
    let ManagedAgentSnapshot::Terminal(snapshot) = snapshot else {
        unreachable!("interactive recovery returned a non-terminal runtime")
    };
    let Some(report) = TaskBoardRuntimeTerminalReport::from_terminal_agent(
        snapshot.status,
        snapshot.error.as_deref(),
        snapshot.signal.as_deref(),
    ) else {
        return Ok(());
    };
    db.project_task_board_runtime_terminal_for_attempt(&recovery.managed_worker_id, &report)
        .await?;
    Ok(())
}
