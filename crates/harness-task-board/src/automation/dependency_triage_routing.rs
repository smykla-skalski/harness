use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::{
    TaskBoardDependencyActionPlan, TaskBoardDependencyCheckState,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageError,
    TaskBoardDependencyTriageResult, compile_task_board_dependency_action_plan,
    validate_task_board_dependency_triage_evidence,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TaskBoardDependencyRouteStatus {
    ReportCompleted,
    HumanRequired { unmet_requirement: String },
    WaitingForChecks { pending_checks: Vec<String> },
    FixRequested,
    ReadyToContinue,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyRouteRecord {
    pub route_id: String,
    pub repository: String,
    pub pull_request_number: u64,
    pub exact_head_revision: String,
    pub status: TaskBoardDependencyRouteStatus,
    pub reason: String,
    pub source_result: TaskBoardDependencyTriageResult,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardDependencyRouteAdmission {
    Claimed,
    Duplicate(Box<TaskBoardDependencyRouteRecord>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyRouteOutcome {
    pub route: TaskBoardDependencyRouteRecord,
    pub created: bool,
}

#[async_trait]
pub trait TaskBoardDependencyRouteStore: Send + Sync {
    /// Atomically claim a route or return the record already stored under its id.
    ///
    /// Implementations must serialize admission by `route_id`. `Claimed` authorizes the caller to
    /// schedule the routed work once; `Duplicate` authorizes no new work.
    ///
    /// # Errors
    ///
    /// Returns a storage error without admitting the route.
    async fn admit(
        &self,
        route: TaskBoardDependencyRouteRecord,
    ) -> Result<TaskBoardDependencyRouteAdmission, CliError>;
}

/// Validate and atomically route one model-produced result without performing a GitHub mutation.
///
/// The returned status is bound to the selected pull request head. Callers may schedule work only
/// when `created` is true; replaying the same result returns the existing route with `created`
/// false.
///
/// # Errors
///
/// Returns a fail-closed validation error, a route-id collision, or a storage error.
pub async fn route_task_board_dependency_triage_result(
    result: &TaskBoardDependencyTriageResult,
    expected_repository: &str,
    expected_pull_request_number: u64,
    expected_head_revision: &str,
    store: &dyn TaskBoardDependencyRouteStore,
) -> Result<TaskBoardDependencyRouteOutcome, CliError> {
    let plan = validate_task_board_dependency_triage_evidence(
        result,
        expected_repository,
        expected_pull_request_number,
        expected_head_revision,
    )
    .and_then(|()| compile_task_board_dependency_action_plan(result))
    .map_err(|error| triage_error(&error))?;
    let route = build_route(result, &plan)?;

    match store.admit(route.clone()).await? {
        TaskBoardDependencyRouteAdmission::Claimed => Ok(TaskBoardDependencyRouteOutcome {
            route,
            created: true,
        }),
        TaskBoardDependencyRouteAdmission::Duplicate(existing) if *existing == route => {
            Ok(TaskBoardDependencyRouteOutcome {
                route: *existing,
                created: false,
            })
        }
        TaskBoardDependencyRouteAdmission::Duplicate(_) => Err(CliErrorKind::workflow_io(format!(
            "dependency triage route id reused for different content: {}",
            route.route_id
        ))
        .into()),
    }
}

fn build_route(
    result: &TaskBoardDependencyTriageResult,
    plan: &TaskBoardDependencyActionPlan,
) -> Result<TaskBoardDependencyRouteRecord, CliError> {
    let terminal = plan
        .actions
        .last()
        .ok_or(TaskBoardDependencyTriageError::ActionPlanContradictsDisposition)
        .map_err(|error| triage_error(&error))?;
    let status = match plan.disposition {
        TaskBoardDependencyTriageDisposition::ReportOnly => {
            TaskBoardDependencyRouteStatus::ReportCompleted
        }
        TaskBoardDependencyTriageDisposition::HumanRequired => {
            TaskBoardDependencyRouteStatus::HumanRequired {
                unmet_requirement: terminal.reason.clone(),
            }
        }
        TaskBoardDependencyTriageDisposition::WaitForChecks => {
            TaskBoardDependencyRouteStatus::WaitingForChecks {
                pending_checks: result
                    .checks
                    .iter()
                    .filter(|check| check.state == TaskBoardDependencyCheckState::Pending)
                    .map(|check| check.name.clone())
                    .collect(),
            }
        }
        TaskBoardDependencyTriageDisposition::FixRequired => {
            TaskBoardDependencyRouteStatus::FixRequested
        }
        TaskBoardDependencyTriageDisposition::ContinueSafe => {
            TaskBoardDependencyRouteStatus::ReadyToContinue
        }
    };

    Ok(TaskBoardDependencyRouteRecord {
        route_id: route_id(result)?,
        repository: terminal.repository.clone(),
        pull_request_number: terminal.pull_request_number,
        exact_head_revision: terminal.exact_head_revision.clone(),
        status,
        reason: terminal.reason.clone(),
        source_result: result.clone(),
    })
}

fn route_id(result: &TaskBoardDependencyTriageResult) -> Result<String, CliError> {
    let encoded = serde_json::to_vec(result).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "dependency triage result could not be fingerprinted: {error}"
        ))
    })?;
    Ok(format!(
        "dependency-triage:sha256:{}",
        hex::encode(Sha256::digest(encoded))
    ))
}

fn triage_error(error: &TaskBoardDependencyTriageError) -> CliError {
    CliErrorKind::workflow_parse(error.to_string()).into()
}

#[cfg(test)]
mod tests;
