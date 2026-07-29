use std::collections::BTreeSet;

use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};

use super::{
    TaskBoardDependencyRouteOutcome, TaskBoardDependencyRouteRecord,
    TaskBoardDependencyRouteStatus, TaskBoardDependencyRouteStore,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
    route_task_board_dependency_triage_result, valid_head_revision,
    validate_task_board_dependency_triage_result,
};

pub const TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION: u32 = 1;
pub const TASK_BOARD_DEPENDENCY_FIXER_MODEL: &str = "gpt-5.4-mini";
pub const TASK_BOARD_DEPENDENCY_FIXER_EFFORT: &str = "low";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyFixBinding {
    pub session_id: String,
    pub board_item_id: String,
    pub workflow_execution_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyFixRequest {
    pub dispatch_id: String,
    pub route_id: String,
    pub session_id: String,
    pub board_item_id: String,
    pub workflow_execution_id: String,
    pub repository: String,
    pub pull_request_number: u64,
    pub exact_head_revision: String,
    pub requested_repair: String,
    pub triage_result: TaskBoardDependencyTriageResult,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyFixRun {
    pub run_id: String,
    pub runtime: String,
    pub requested_model: String,
    pub requested_effort: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyFixResult {
    pub schema_version: u32,
    pub dispatch_id: String,
    pub route_id: String,
    pub base_head_revision: String,
    pub head_revision: String,
    pub summary: String,
    pub changed_paths: Vec<String>,
    pub validation: Vec<String>,
    pub remaining_blockers: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyFixDispatchOutcome {
    pub route: TaskBoardDependencyRouteRecord,
    pub created: bool,
    pub run: Option<TaskBoardDependencyFixRun>,
}

#[async_trait]
pub trait TaskBoardDependencyFixLauncher: Send + Sync {
    /// Start or recover the deterministic fixer run for this dispatch.
    ///
    /// # Errors
    ///
    /// Returns a runtime or persistence error without reporting a started run.
    async fn start(
        &self,
        request: &TaskBoardDependencyFixRequest,
    ) -> Result<TaskBoardDependencyFixRun, CliError>;
}

/// Convert an explicit code-change route into one exact-head Codex dispatch.
///
/// # Errors
///
/// Rejects every non-fix disposition and any incomplete or inconsistent binding.
pub fn task_board_dependency_fix_request(
    route: &TaskBoardDependencyRouteRecord,
    binding: &TaskBoardDependencyFixBinding,
) -> Result<TaskBoardDependencyFixRequest, CliError> {
    if route.status != TaskBoardDependencyRouteStatus::FixRequested
        || route.source_result.disposition != TaskBoardDependencyTriageDisposition::FixRequired
    {
        return Err(parse_error(
            "dependency triage route does not explicitly require a code fix",
        ));
    }
    validate_task_board_dependency_triage_result(
        &route.source_result,
        &route.repository,
        route.pull_request_number,
        &route.exact_head_revision,
    )
    .map_err(|error| parse_error(error.to_string()))?;
    if [
        route.route_id.as_str(),
        route.reason.as_str(),
        binding.session_id.as_str(),
        binding.board_item_id.as_str(),
        binding.workflow_execution_id.as_str(),
    ]
    .iter()
    .any(|value| value.trim().is_empty() || value.trim() != *value)
    {
        return Err(parse_error(
            "dependency fixer dispatch has incomplete exact-head context",
        ));
    }
    Ok(TaskBoardDependencyFixRequest {
        dispatch_id: format!("{}:fix", route.route_id),
        route_id: route.route_id.clone(),
        session_id: binding.session_id.clone(),
        board_item_id: binding.board_item_id.clone(),
        workflow_execution_id: binding.workflow_execution_id.clone(),
        repository: route.repository.clone(),
        pull_request_number: route.pull_request_number,
        exact_head_revision: route.exact_head_revision.clone(),
        requested_repair: route.reason.clone(),
        triage_result: route.source_result.clone(),
    })
}

/// Start the fixer only after the route has passed the explicit-fix gate.
///
/// # Errors
///
/// Returns request validation or launcher errors.
pub async fn dispatch_task_board_dependency_fix(
    route: &TaskBoardDependencyRouteRecord,
    binding: &TaskBoardDependencyFixBinding,
    launcher: &dyn TaskBoardDependencyFixLauncher,
) -> Result<TaskBoardDependencyFixRun, CliError> {
    let request = task_board_dependency_fix_request(route, binding)?;
    launcher.start(&request).await
}

/// Route one validated triage result and idempotently start its fixer when required.
///
/// # Errors
///
/// Returns route admission, validation, or launcher errors without dispatching non-fix outcomes.
pub async fn route_and_dispatch_task_board_dependency_fix(
    result: &TaskBoardDependencyTriageResult,
    expected_repository: &str,
    expected_pull_request_number: u64,
    expected_head_revision: &str,
    store: &dyn TaskBoardDependencyRouteStore,
    binding: &TaskBoardDependencyFixBinding,
    launcher: &dyn TaskBoardDependencyFixLauncher,
) -> Result<TaskBoardDependencyFixDispatchOutcome, CliError> {
    let TaskBoardDependencyRouteOutcome { route, created } =
        route_task_board_dependency_triage_result(
            result,
            expected_repository,
            expected_pull_request_number,
            expected_head_revision,
            store,
        )
        .await?;
    let run = if route.status == TaskBoardDependencyRouteStatus::FixRequested {
        Some(dispatch_task_board_dependency_fix(&route, binding, launcher).await?)
    } else {
        None
    };
    Ok(TaskBoardDependencyFixDispatchOutcome {
        route,
        created,
        run,
    })
}

/// Render the bounded repair task and its structured response contract.
///
/// # Errors
///
/// Returns a serialization error if the validated triage evidence cannot be encoded.
pub fn render_task_board_dependency_fix_prompt(
    request: &TaskBoardDependencyFixRequest,
) -> Result<String, CliError> {
    let triage = serde_json::to_string_pretty(&request.triage_result).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "dependency fixer triage evidence could not be encoded: {error}"
        ))
    })?;
    let response = TaskBoardDependencyFixResult {
        schema_version: TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
        dispatch_id: request.dispatch_id.clone(),
        route_id: request.route_id.clone(),
        base_head_revision: request.exact_head_revision.clone(),
        head_revision: "REPLACE_WITH_CURRENT_HEAD".into(),
        summary: "concise repair summary".into(),
        changed_paths: vec!["path/to/changed-file".into()],
        validation: vec!["focused validation command and outcome".into()],
        remaining_blockers: Vec::new(),
    };
    let response = serde_json::to_string_pretty(&response).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "dependency fixer result template could not be encoded: {error}"
        ))
    })?;
    Ok(format!(
        "Repair dependency update pull request {repository}#{number} at exact head {head}.\n\
         Do not work from or publish against another revision.\n\
         Requested repair: {repair}\n\n\
         Triage report and check evidence:\n{triage}\n\n\
         Make only the changes required by this repair. Run the smallest relevant validation.\n\
         Return exactly one JSON object matching this contract:\n{response}",
        repository = request.repository,
        number = request.pull_request_number,
        head = request.exact_head_revision,
        repair = request.requested_repair,
    ))
}

/// Decode and validate the result produced by one exact-head fixer run.
///
/// # Errors
///
/// Rejects malformed, mismatched, empty, duplicated, or internally contradictory evidence.
pub fn parse_task_board_dependency_fix_result(
    report: &str,
    request: &TaskBoardDependencyFixRequest,
) -> Result<TaskBoardDependencyFixResult, CliError> {
    let result = serde_json::from_str::<TaskBoardDependencyFixResult>(report).map_err(|error| {
        parse_error(format!(
            "dependency fixer result is not valid JSON for the required schema: {error}"
        ))
    })?;
    validate_task_board_dependency_fix_result(&result, request)?;
    Ok(result)
}

fn validate_task_board_dependency_fix_result(
    result: &TaskBoardDependencyFixResult,
    request: &TaskBoardDependencyFixRequest,
) -> Result<(), CliError> {
    if result.schema_version != TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION
        || result.dispatch_id != request.dispatch_id
        || result.route_id != request.route_id
        || result.base_head_revision != request.exact_head_revision
        || !valid_head_revision(&result.head_revision)
        || result.summary.trim().is_empty()
        || result.summary.trim() != result.summary
    {
        return Err(parse_error(
            "dependency fixer result does not match its exact-head dispatch",
        ));
    }
    validate_unique_text(&result.changed_paths, "changed paths")?;
    validate_unique_text(&result.validation, "validation evidence")?;
    validate_unique_text(&result.remaining_blockers, "remaining blockers")?;
    if result.changed_paths.is_empty() {
        if result.remaining_blockers.is_empty() || result.head_revision != result.base_head_revision
        {
            return Err(parse_error(
                "dependency fixer result has no changes and no blocking explanation",
            ));
        }
    } else if result.head_revision == result.base_head_revision || result.validation.is_empty() {
        return Err(parse_error(
            "dependency fixer result changed files without a new head and validation",
        ));
    }
    Ok(())
}

fn validate_unique_text(values: &[String], label: &str) -> Result<(), CliError> {
    let mut unique = BTreeSet::new();
    if values.iter().any(|value| {
        value.trim().is_empty() || value.trim() != value || !unique.insert(value.as_str())
    }) {
        return Err(parse_error(format!(
            "dependency fixer result has invalid {label}"
        )));
    }
    Ok(())
}

fn parse_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(detail.into()).into()
}

#[cfg(test)]
mod tests;
