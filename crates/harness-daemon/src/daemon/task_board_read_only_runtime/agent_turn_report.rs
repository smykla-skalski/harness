//! Starts a supported agent-turn reviewer runtime for a durable board attempt.
//!
//! `OpenRouter` runs the shared turn through the `agent_turn_runs` store. The run
//! is correlated to the attempt's managed run id so start-by-id, restart
//! reconciliation, and admission release all key on the coordinator's attempt
//! rather than a self-generated turn id.

use crate::agents::turn::{AgentTurnPullRequestContext, AgentTurnRequest, AgentTurnRuntime};
use crate::daemon::agent_acp::{
    AgentTurnFailureCategory, OpenRouterAgentTurnRuntime, OpenRouterRunCorrelation,
};
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
    if start.runtime != "openrouter" {
        return Err(CliErrorKind::invalid_transition(format!(
            "unsupported agent-turn reviewer runtime '{}'",
            start.runtime
        ))
        .into());
    }
    let store = state.async_db.get().cloned().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "agent-turn report run needs the canonical async database",
        ))
    })?;
    let runtime = OpenRouterAgentTurnRuntime::new_correlated(
        state.acp_agent_manager.clone(),
        start.session_id.to_string(),
        start.project_dir,
        store,
        OpenRouterRunCorrelation {
            run_id: start.run_id.to_string(),
            board_item_id: Some(start.board_item_id.to_string()),
            workflow_execution_id: Some(start.workflow_execution_id.to_string()),
            task_id: None,
        },
    );
    runtime
        .start(AgentTurnRequest {
            prompt: start.prompt,
            requested_model: start.requested_model,
            pull_request: start.pull_request,
        })
        .await
        .map(|_| ())
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
    let Some(agent) = inspect
        .agents
        .into_iter()
        .find(|agent| agent.acp_id == runtime_turn_id)
    else {
        run.status = AgentTurnRunStatus::Failed;
        run.error = Some("provider turn is no longer attached to this daemon".into());
        run.updated_at = harness_workspace::workspace::utc_now();
        db.save_agent_turn_run(&run).await?;
        return db.agent_turn_run(run_id).await;
    };
    let Some(session) = agent.session_state else {
        return Ok(Some(run));
    };
    let terminal_observed =
        session.last_turn_result.is_some() || session.last_turn_failure.is_some();
    if !terminal_observed {
        return Ok(Some(run));
    }
    run.actual_model = session
        .config_options
        .iter()
        .find(|option| option.id == "harness_provider_effective_model")
        .map(|option| option.current_value.clone());
    run.report = session
        .last_turn_result
        .as_ref()
        .map(|result| result.report.clone())
        .or_else(|| session.last_turn_partial_output.clone());
    if let Err(detail) =
        verify_effective_model(run.requested_model.as_deref(), run.actual_model.as_deref())
    {
        run.status = AgentTurnRunStatus::Failed;
        run.error = Some(detail);
        run.updated_at = harness_workspace::workspace::utc_now();
        db.save_agent_turn_run(&run).await?;
        return db.agent_turn_run(run_id).await;
    }
    if let Some(result) = session.last_turn_result {
        run.status = AgentTurnRunStatus::Completed;
        run.report = Some(result.report);
        run.stop_reason = Some(result.stop_reason);
    } else if let Some(failure) = session.last_turn_failure {
        run.report = session.last_turn_partial_output;
        run.status = if failure.category == AgentTurnFailureCategory::Cancelled {
            AgentTurnRunStatus::Cancelled
        } else {
            AgentTurnRunStatus::Failed
        };
        if run.status == AgentTurnRunStatus::Cancelled {
            run.stop_reason = Some(failure.detail);
        } else {
            run.error = Some(failure.detail);
        }
    }
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
