use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{Sqlite, Transaction, query_as};

use super::admission_reservations::admission_usage_in_tx;
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::{
    TaskBoardAdmissionDecision, TaskBoardAdmissionRequirement, TaskBoardAutomationPolicy,
    TaskBoardItem, TaskBoardLaunchCapability, TaskBoardOrchestratorSettings,
    TaskBoardPolicyCompilationContext, TaskBoardPolicyCompilationError, compile_task_board_policy,
    evaluate_admission_requirements, launch_capability_for_agent_mode,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct TaskBoardDispatchAdmissionSnapshot {
    pub(crate) decision_id: String,
    pub(crate) generation: i64,
    pub(crate) item_revision: i64,
    pub(crate) settings_revision: i64,
    pub(crate) policy: TaskBoardAutomationPolicy,
    pub(crate) context: TaskBoardPolicyCompilationContext,
    pub(crate) decision: TaskBoardAdmissionDecision,
    pub(crate) requirements: Vec<TaskBoardAdmissionRequirement>,
    pub(crate) blockers: Value,
    pub(crate) next_available_at: Option<String>,
    pub(crate) launch_capability: Option<TaskBoardLaunchCapability>,
    pub(crate) evaluated_at: String,
}

impl TaskBoardDispatchAdmissionSnapshot {
    pub(crate) const fn is_allowed(&self) -> bool {
        matches!(self.decision, TaskBoardAdmissionDecision::Allowed)
    }

    pub(crate) fn refusal_message(&self) -> String {
        let disposition = match self.decision {
            TaskBoardAdmissionDecision::Allowed => "allowed",
            TaskBoardAdmissionDecision::Deferred => "deferred",
            TaskBoardAdmissionDecision::Rejected => "rejected",
        };
        let detail = self
            .blockers
            .as_array()
            .filter(|values| !values.is_empty())
            .map_or_else(String::new, |values| {
                format!(": {}", Value::Array(values.clone()))
            });
        format!("task-board dispatch admission {disposition}{detail}")
    }
}

pub(super) async fn evaluate_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    item_revision: i64,
    excluded_intent_id: Option<&str>,
) -> Result<Option<TaskBoardDispatchAdmissionSnapshot>, CliError> {
    let (policy, settings_revision) = load_admission_policy_in_tx(transaction).await?;
    let evaluated_at = utc_now();
    let context = TaskBoardPolicyCompilationContext {
        workflow_kind: item.workflow_kind,
        repository: item.execution_repository.clone(),
        evaluated_at: evaluated_at.clone(),
        estimated_tokens: item.estimated_tokens,
        estimated_cost_microusd: item.estimated_cost_microusd,
    };
    let launch_capability = match launch_capability_for_agent_mode(item.agent_mode) {
        Ok(capability) => Some(capability),
        Err(error) => {
            let message = error.to_string();
            return Ok(Some(rejected_candidate(
                policy,
                context,
                item_revision,
                settings_revision,
                evaluated_at,
                &message,
            )));
        }
    };
    if policy.limits.is_empty() && policy.windows.is_empty() {
        return Ok(None);
    }
    let compiled = match compile_task_board_policy(&policy, &context) {
        Ok(compiled) => compiled,
        Err(error) => {
            let message = policy_error(&error);
            return Ok(Some(rejected_candidate(
                policy,
                context,
                item_revision,
                settings_revision,
                evaluated_at,
                &message,
            )));
        }
    };
    let usage = admission_usage_in_tx(
        transaction,
        &compiled.requirements,
        &compiled.evaluated_at,
        excluded_intent_id,
    )
    .await?;
    let evaluation =
        evaluate_admission_requirements(compiled.requirements, usage, &compiled.evaluated_at)
            .map_err(|error| db_error(format!("evaluate task board admission: {error}")))?;
    let blockers = serde_json::to_value(&evaluation.blockers)
        .map_err(|error| db_error(format!("serialize task board admission blockers: {error}")))?;
    Ok(Some(TaskBoardDispatchAdmissionSnapshot {
        decision_id: String::new(),
        generation: 0,
        item_revision,
        settings_revision,
        policy,
        context,
        decision: evaluation.decision,
        requirements: evaluation.requirements,
        blockers,
        next_available_at: evaluation.next_available_at,
        launch_capability,
        evaluated_at: evaluation.evaluated_at,
    }))
}

async fn load_admission_policy_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<(TaskBoardAutomationPolicy, i64), CliError> {
    let (settings_json, revision) = query_as::<_, (String, i64)>(
        "SELECT settings_json, revision
         FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board admission settings: {error}")))?;
    let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
        .map_err(|error| db_error(format!("decode task board admission settings: {error}")))?;
    Ok((settings.admission_policy, revision))
}

fn rejected_candidate(
    policy: TaskBoardAutomationPolicy,
    context: TaskBoardPolicyCompilationContext,
    item_revision: i64,
    settings_revision: i64,
    evaluated_at: String,
    message: &str,
) -> TaskBoardDispatchAdmissionSnapshot {
    TaskBoardDispatchAdmissionSnapshot {
        decision_id: String::new(),
        generation: 0,
        item_revision,
        settings_revision,
        policy,
        context,
        decision: TaskBoardAdmissionDecision::Rejected,
        requirements: Vec::new(),
        blockers: json!([{"kind": "policy_compilation", "message": message}]),
        next_available_at: None,
        launch_capability: None,
        evaluated_at,
    }
}

fn policy_error(error: &TaskBoardPolicyCompilationError) -> String {
    error.to_string()
}
