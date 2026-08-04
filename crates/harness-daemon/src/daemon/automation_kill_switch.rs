use futures_util::future::join_all;
use std::collections::BTreeSet;

use crate::daemon::db::prelude::AsyncAgentTurnRunQueries;
use crate::daemon::db::task_board::prelude::{AutomationKillSwitchQueries, PolicyRuntimeQueries};
use crate::daemon::db::{AgentTurnStopTarget, AsyncDaemonDb};
use crate::daemon::http::{
    DaemonHttpState, run_acp_agent_blocking, run_codex_agent_blocking, run_terminal_agent_blocking,
};
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::daemon::reviews_store::PolicyGraphQueries;
use harness_kernel::errors::CliError;

pub(crate) async fn enforce_automation_kill_switch(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
) -> Result<bool, CliError> {
    let plan = db.automation_kill_switch_stop_plan().await?;
    if !plan.engaged {
        return Ok(false);
    }
    crate::daemon::service::enforce_task_board_orchestrator_kill_switch_db(db).await?;
    db.cancel_active_policy_workflow_runs("automation kill switch engaged")
        .await?;
    let acp_run_ids = active_acp_run_ids(state, &plan.agent_turns).await;
    let (codex, terminal, acp, agent_turns) = tokio::join!(
        stop_codex_runs(state, plan.codex_run_ids),
        stop_terminal_runs(state, plan.terminal_run_ids),
        stop_acp_runs(state, acp_run_ids),
        cancel_agent_turns(db, plan.agent_turns),
    );
    for error in codex
        .into_iter()
        .chain(terminal)
        .chain(acp)
        .chain(agent_turns)
    {
        tracing::warn!(%error, "automation kill switch worker stop will be retried");
    }
    Ok(true)
}

pub(crate) async fn enforce_policy_automation_control(
    db: &AsyncDaemonDb,
) -> Result<bool, CliError> {
    let workspace = db.load_policy_workspace().await?;
    let disabled = workspace.is_some_and(|workspace| {
        workspace.spawn_kill_switch || !workspace.global_policy_enforcement_enabled
    });
    if disabled {
        db.cancel_active_policy_workflow_runs("policy automation disabled")
            .await?;
    }
    Ok(disabled)
}

pub(crate) async fn enforce_triage_automation_control(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
) -> Result<bool, CliError> {
    let plan = db.triage_automation_stop_plan().await?;
    if !plan.disabled {
        return Ok(false);
    }
    for error in stop_codex_runs(state, plan.codex_run_ids).await {
        tracing::warn!(%error, "triage automation worker stop will be retried");
    }
    Ok(true)
}

async fn active_acp_run_ids(
    state: &DaemonHttpState,
    agent_turns: &[AgentTurnStopTarget],
) -> Vec<String> {
    let mut run_ids: BTreeSet<String> = agent_turns
        .iter()
        .map(|target| target.runtime_turn_id.clone())
        .collect();
    match run_acp_agent_blocking(state, "automation kill switch inspect", |manager| {
        manager.inspect(None)
    })
    .await
    {
        Ok(response) => {
            run_ids.extend(response.agents.into_iter().map(|snapshot| snapshot.acp_id));
        }
        Err(error) => {
            tracing::warn!(%error, "automation kill switch ACP inspection failed");
        }
    }
    run_ids.into_iter().collect()
}

pub(crate) async fn require_automation_kill_switch_clear(
    state: &DaemonHttpState,
) -> Result<(), CliError> {
    let Some(db) = state.async_db.get() else {
        return Ok(());
    };
    if db.automation_kill_switch_engaged().await? {
        return Err(harness_kernel::errors::CliErrorKind::invalid_transition(
            "automation kill switch is engaged",
        )
        .into());
    }
    Ok(())
}

pub(crate) async fn fence_started_managed_agent(
    state: &DaemonHttpState,
    snapshot: ManagedAgentSnapshot,
) -> Result<ManagedAgentSnapshot, CliError> {
    let Some(db) = state.async_db.get() else {
        return Ok(snapshot);
    };
    if !db.automation_kill_switch_engaged().await? {
        return Ok(snapshot);
    }
    let run_id = snapshot.agent_id().to_string();
    match &snapshot {
        ManagedAgentSnapshot::Terminal(_) => {
            let target = run_id.clone();
            run_terminal_agent_blocking(state, "automation kill switch fence", move |manager| {
                manager.stop(&target)
            })
            .await
            .map(|_| ())
        }
        ManagedAgentSnapshot::Codex(_) => {
            let target = run_id.clone();
            run_codex_agent_blocking(state, "automation kill switch fence", move |controller| {
                controller.stop(&target)
            })
            .await
            .map(|_| ())
        }
        ManagedAgentSnapshot::Acp(_) => {
            let target = run_id.clone();
            run_acp_agent_blocking(state, "automation kill switch fence", move |manager| {
                manager.stop(&target)
            })
            .await
            .map(|_| ())
        }
    }
    .map_err(|error| stop_error("newly started", &run_id, &error))?;
    Err(harness_kernel::errors::CliErrorKind::invalid_transition(
        "automation kill switch engaged while starting a managed agent",
    )
    .into())
}

async fn stop_codex_runs(state: &DaemonHttpState, run_ids: Vec<String>) -> Vec<CliError> {
    join_all(run_ids.into_iter().map(|run_id| {
        let state = state.clone();
        async move {
            let target = run_id.clone();
            run_codex_agent_blocking(&state, "automation kill switch", move |controller| {
                controller.stop(&target)
            })
            .await
            .map(|_| ())
            .map_err(|error| stop_error("Codex", &run_id, &error))
        }
    }))
    .await
    .into_iter()
    .filter_map(Result::err)
    .collect()
}

async fn stop_terminal_runs(state: &DaemonHttpState, run_ids: Vec<String>) -> Vec<CliError> {
    join_all(run_ids.into_iter().map(|run_id| {
        let state = state.clone();
        async move {
            let target = run_id.clone();
            run_terminal_agent_blocking(&state, "automation kill switch", move |manager| {
                manager.stop(&target)
            })
            .await
            .map(|_| ())
            .map_err(|error| stop_error("terminal", &run_id, &error))
        }
    }))
    .await
    .into_iter()
    .filter_map(Result::err)
    .collect()
}

async fn stop_acp_runs(state: &DaemonHttpState, run_ids: Vec<String>) -> Vec<CliError> {
    join_all(run_ids.into_iter().map(|run_id| {
        let state = state.clone();
        async move {
            let target = run_id.clone();
            run_acp_agent_blocking(&state, "automation kill switch", move |manager| {
                manager.stop(&target)
            })
            .await
            .map(|_| ())
            .map_err(|error| stop_error("ACP", &run_id, &error))
        }
    }))
    .await
    .into_iter()
    .filter_map(Result::err)
    .collect()
}

async fn cancel_agent_turns(
    db: &AsyncDaemonDb,
    targets: Vec<AgentTurnStopTarget>,
) -> Vec<CliError> {
    join_all(targets.into_iter().map(|target| {
        let db = db.clone();
        async move {
            db.cancel_agent_turn_run(&target.run_id)
                .await
                .map_err(|error| stop_error("agent turn", &target.run_id, &error))
        }
    }))
    .await
    .into_iter()
    .filter_map(Result::err)
    .collect()
}

fn stop_error(runtime: &str, run_id: &str, error: &CliError) -> CliError {
    harness_kernel::errors::CliErrorKind::workflow_io(format!(
        "stop {runtime} run '{run_id}': {error}"
    ))
    .into()
}
