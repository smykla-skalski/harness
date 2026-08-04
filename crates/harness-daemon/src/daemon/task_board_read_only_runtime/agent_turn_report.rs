//! Starts a supported agent-turn reviewer runtime for a durable board attempt.
//!
//! `OpenRouter` runs the shared turn through the `agent_turn_runs` store. The run
//! is correlated to the attempt's managed run id so start-by-id, restart
//! reconciliation, and admission release all key on the coordinator's attempt
//! rather than a self-generated turn id.

use crate::agents::turn::{AgentTurnPullRequestContext, AgentTurnRequest, AgentTurnRuntime};
use crate::daemon::agent_acp::{
    AgentTurnSettlement, OpenRouterAgentTurnRuntime, OpenRouterRunCorrelation,
};
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::AutomationKillSwitchQueries;
use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncDaemonDb};
use crate::daemon::http::DaemonHttpState;
use harness_kernel::errors::{CliError, CliErrorKind};

/// Everything an agent-turn report start needs from the frozen attempt, apart
/// from the runtime handle the production state supplies.
pub(crate) struct AgentTurnReportStart<'a> {
    pub(crate) runtime: &'a str,
    pub(crate) session_id: &'a str,
    pub(crate) project_dir: Option<String>,
    pub(crate) prompt: String,
    pub(crate) requested_model: Option<String>,
    pub(crate) pull_request: Option<AgentTurnPullRequestContext>,
    /// The attempt's managed run id; the durable run and its concurrency
    /// admission key on this exact value.
    pub(crate) run_id: &'a str,
    pub(crate) board_item_id: &'a str,
    pub(crate) workflow_execution_id: &'a str,
}

/// Start the named agent-turn runtime for one report attempt, recording it in
/// the `agent_turn_runs` store keyed to the attempt.
///
/// # Errors
///
/// Returns an error when the runtime is not a supported agent-turn runtime, the
/// durable store is unavailable, or the runtime cannot accept the turn.
pub(crate) async fn start_agent_turn_report_run(
    state: &DaemonHttpState,
    start: AgentTurnReportStart<'_>,
) -> Result<(), CliError> {
    let store = state.async_db.get().cloned().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "agent-turn report run needs the canonical async database",
        ))
    })?;
    if store.automation_kill_switch_engaged().await? {
        return Err(CliErrorKind::invalid_transition("automation kill switch is engaged").into());
    }
    if start.runtime != "openrouter" {
        return Err(CliErrorKind::invalid_transition(format!(
            "unsupported agent-turn reviewer runtime '{}'",
            start.runtime
        ))
        .into());
    }
    let runtime = OpenRouterAgentTurnRuntime::new_correlated(
        state.acp_agent_manager.clone(),
        start.session_id.to_string(),
        start.project_dir,
        store.clone(),
        OpenRouterRunCorrelation {
            run_id: start.run_id.to_string(),
            board_item_id: Some(start.board_item_id.to_string()),
            workflow_execution_id: Some(start.workflow_execution_id.to_string()),
            task_id: None,
        },
    );
    let turn_id = runtime
        .start(AgentTurnRequest {
            prompt: start.prompt,
            requested_model: start.requested_model,
            pull_request: start.pull_request,
        })
        .await?;
    if store.automation_kill_switch_engaged().await? {
        runtime.cancel(&turn_id).await?;
        return Err(CliErrorKind::invalid_transition(
            "automation kill switch engaged while starting an agent turn",
        )
        .into());
    }
    Ok(())
}

/// Load one durable agent-turn report and harvest a live terminal ACP result when available.
///
/// # Errors
///
/// Returns an error when the durable row is malformed, live inspection fails, or settlement
/// cannot be persisted.
pub(crate) async fn load_agent_turn_report_run(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    run_id: &str,
) -> Result<Option<AgentTurnRunSnapshot>, CliError> {
    let Some(mut run) = db.agent_turn_run(run_id).await? else {
        return Ok(None);
    };
    if !run.status.is_active() {
        return Ok(Some(run));
    }
    let session_id = run.session_id.as_deref().ok_or_else(|| {
        CliErrorKind::workflow_io("active agent-turn report has no Harness session")
    })?;
    let runtime_turn_id = run.runtime_turn_id.as_deref().ok_or_else(|| {
        CliErrorKind::workflow_io("active agent-turn report has no provider turn identity")
    })?;
    let inspect = state.acp_agent_manager.inspect(Some(session_id))?;
    if !inspect.available {
        return Ok(Some(run));
    }
    let agent = inspect
        .agents
        .into_iter()
        .find(|agent| agent.acp_id == runtime_turn_id);
    let is_detached = agent.is_none();
    let session = match agent {
        Some(agent) => agent.session_state,
        // `inspect` hides a session whose process already exited, so a turn that
        // failed and then detached still has its provider outcome here.
        None => state
            .acp_agent_manager
            .detached_turn_state(session_id, runtime_turn_id)?,
    };
    let settlement = session
        .as_ref()
        .and_then(AgentTurnSettlement::from_session_state);
    let Some(settlement) = settlement else {
        if !is_detached {
            return Ok(Some(run));
        }
        // Nothing was ever observed, so the detachment itself is the outcome.
        // The unverified model stays untouched: there is no observation to
        // check it against.
        let detachment = AgentTurnSettlement::detached();
        run.status = detachment.status;
        run.error = detachment.error;
        return save_and_reload(db, run, run_id).await;
    };
    run.actual_model = settlement.actual_model;
    run.report = settlement.report;
    match verify_effective_model(run.requested_model.as_deref(), run.actual_model.as_deref()) {
        Ok(()) => {
            run.status = settlement.status;
            run.stop_reason = settlement.stop_reason;
            run.error = settlement.error;
        }
        // A mismatch overrides the outcome but keeps whatever the provider
        // produced, so the evidence survives the rejection.
        Err(detail) => {
            run.status = AgentTurnRunStatus::Failed;
            run.error = Some(detail);
        }
    }
    save_and_reload(db, run, run_id).await
}

async fn save_and_reload(
    db: &AsyncDaemonDb,
    mut run: AgentTurnRunSnapshot,
    run_id: &str,
) -> Result<Option<AgentTurnRunSnapshot>, CliError> {
    run.updated_at = harness_workspace::workspace::utc_now();
    db.save_agent_turn_run(&run).await?;
    db.agent_turn_run(run_id).await
}

fn verify_effective_model(
    requested_model: Option<&str>,
    actual_model: Option<&str>,
) -> Result<(), String> {
    let Some(requested_model) = requested_model else {
        return Ok(());
    };
    if actual_model == Some(requested_model) {
        return Ok(());
    }
    Err(format!(
        "provider effective model mismatch: requested '{requested_model}', observed '{}'",
        actual_model.unwrap_or("<missing>")
    ))
}

#[cfg(test)]
mod tests {
    use super::verify_effective_model;

    #[test]
    fn effective_model_accepts_an_exact_match() {
        assert!(verify_effective_model(Some("deepseek/v4"), Some("deepseek/v4")).is_ok());
    }

    #[test]
    fn effective_model_rejects_a_mismatch_and_missing_observation() {
        for observed in [Some("other/model"), None] {
            let error = verify_effective_model(Some("deepseek/v4"), observed)
                .expect_err("mismatch must fail");
            assert!(error.contains("deepseek/v4"));
            assert!(error.contains(observed.unwrap_or("<missing>")));
        }
    }

    #[test]
    fn provider_default_profiles_do_not_gain_a_false_requested_model() {
        assert!(verify_effective_model(None, Some("provider/default")).is_ok());
    }
}
