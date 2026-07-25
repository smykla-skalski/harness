use std::collections::BTreeMap;

use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::prompt_catalog::{PromptId, render_prompt};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardEvaluationResult, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardImplementationResult, TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict,
    TaskBoardReadOnlyRunContext, TaskBoardReviewResult, TaskBoardReviewerOutcome,
    TaskBoardReviewerProfile, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    validate_task_board_read_only_run_context,
};

pub(crate) fn codex_attempt_request(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<CodexRunRequest, CliError> {
    codex_attempt_request_for_target(execution, attempt, TaskBoardCodexLaunchTarget::Local)
}

pub(crate) fn remote_codex_attempt_request(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<CodexRunRequest, CliError> {
    codex_attempt_request_for_target(execution, attempt, TaskBoardCodexLaunchTarget::Remote)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TaskBoardCodexLaunchTarget {
    Local,
    Remote,
}

fn codex_attempt_request_for_target(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    target: TaskBoardCodexLaunchTarget,
) -> Result<CodexRunRequest, CliError> {
    if execution.transition.phase == Some(TaskBoardExecutionPhase::Implementation) {
        write_implementation_request(execution, attempt, target)
    } else {
        codex_report_request_for_target(execution, attempt, target)
    }
}

fn codex_report_request_for_target(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    target: TaskBoardCodexLaunchTarget,
) -> Result<CodexRunRequest, CliError> {
    let profile = attempt_profile(execution, attempt)?;
    let context = run_context(execution)?;
    let prompt = match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Review) => {
            review_prompt(execution, context, attempt, &profile.id, target)?
        }
        Some(TaskBoardExecutionPhase::Evaluate) => evaluation_prompt(execution, context, attempt)?,
        _ => {
            return Err(invalid_transition(
                "Codex Report request requires Review or Evaluate phase",
            ));
        }
    };
    let phase_name =
        if attempt.action_key == "evaluate" || attempt.action_key.starts_with("evaluate:") {
            "Evaluation"
        } else {
            "Review"
        };
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt,
        mode: CodexRunMode::Report,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: read_only_capabilities(
            &execution.item_id,
            &context.tags,
            &attempt.idempotency_key,
        ),
        name: Some(format!("Task Board {phase_name}: {}", context.title)),
        persona: Some(profile.persona.clone()),
        resume_thread_id: None,
        task_id: None,
        board_item_id: Some(execution.item_id.clone()),
        workflow_execution_id: Some(execution.execution_id.clone()),
        model: profile.model.clone(),
        effort: profile.effort.clone(),
        allow_custom_model: false,
    })
}

pub(super) fn attempt_profile<'a>(
    execution: &'a TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<&'a TaskBoardReviewerProfile, CliError> {
    let profile_id = attempt
        .action_key
        .strip_prefix("review:")
        .or_else(|| {
            (attempt.action_key == "evaluate" || attempt.action_key.starts_with("evaluate:"))
                .then_some("")
        })
        .ok_or_else(|| invalid_transition("Codex Report attempt has an invalid action key"))?;
    if profile_id.is_empty() {
        return execution
            .resolved_reviewers
            .profiles
            .first()
            .ok_or_else(|| invalid_transition("workflow has no evaluator profile"));
    }
    execution
        .resolved_reviewers
        .profiles
        .iter()
        .find(|profile| profile.id == profile_id)
        .ok_or_else(|| invalid_transition("attempt reviewer is not in the frozen profile set"))
}

fn write_implementation_request(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    target: TaskBoardCodexLaunchTarget,
) -> Result<CodexRunRequest, CliError> {
    let context = run_context(execution)?;
    let task_id = write_task_id(execution)?;
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: implementation_prompt(execution, context, attempt, target)?,
        mode: CodexRunMode::WorkspaceWrite,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: write_capabilities(
            &execution.item_id,
            &context.tags,
            &attempt.idempotency_key,
        ),
        name: Some(format!("Task Board Implementation: {}", context.title)),
        persona: None,
        resume_thread_id: None,
        task_id: Some(task_id.to_string()),
        board_item_id: Some(execution.item_id.clone()),
        workflow_execution_id: Some(execution.execution_id.clone()),
        model: None,
        effort: None,
        allow_custom_model: false,
    })
}

pub(super) fn write_task_id(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<&str, CliError> {
    execution
        .ownership
        .resources
        .get("task_id")
        .filter(|value| !value.trim().is_empty())
        .map(String::as_str)
        .ok_or_else(|| invalid_transition("write workflow has no frozen task id"))
}

fn implementation_prompt(
    execution: &TaskBoardWorkflowExecutionRecord,
    context: &TaskBoardReadOnlyRunContext,
    attempt: &TaskBoardExecutionAttemptRecord,
    target: TaskBoardCodexLaunchTarget,
) -> Result<String, CliError> {
    let base_head = exact_head(execution)?;
    let planning = execution
        .artifacts
        .planning_result
        .as_ref()
        .ok_or_else(|| invalid_transition("write workflow has no approved plan"))?;
    let cycle = execution.artifacts.current_revision_cycle;
    let response = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: execution.execution_id.clone(),
        action_key: attempt.action_key.clone(),
        attempt: attempt.attempt,
        idempotency_key: attempt.idempotency_key.clone(),
        exact_head_revision: "REPLACE_WITH_CURRENT_HEAD".into(),
        artifact: TaskBoardAttemptResultArtifact::Implementation(TaskBoardImplementationResult {
            revision_cycle: cycle,
            base_head_revision: base_head.to_string(),
            head_revision: "REPLACE_WITH_CURRENT_HEAD".into(),
            summary: "concise implementation summary".into(),
            evidence: vec!["focused validation and owning gate results".into()],
        }),
    };
    let criteria = planning
        .acceptance_criteria
        .iter()
        .map(|criterion| format!("- {criterion}"))
        .collect::<Vec<_>>()
        .join("\n");
    let mut variables = BTreeMap::from([
        ("board_item_id", execution.item_id.clone()),
        ("title", context.title.clone()),
        ("workspace_directive", workspace_directive(context, target)),
        ("base_head_revision", base_head.to_string()),
        ("plan_markdown", planning.plan_markdown.clone()),
        ("acceptance_criteria", criteria),
        ("execution_id", execution.execution_id.clone()),
        ("managed_run_id", attempt.idempotency_key.clone()),
        (
            "response_json",
            serde_json::to_string_pretty(&response).map_err(|error| {
                invalid_transition(format!("serialize implementation result template: {error}"))
            })?,
        ),
    ]);
    push_worktree(&mut variables, context, target);
    render_prompt(PromptId::WriteImplementation, &variables)
}

/// The raw worktree only exists for a local run; a remote executor checkout is
/// named by the workspace directive alone.
fn push_worktree(
    variables: &mut BTreeMap<&'static str, String>,
    context: &TaskBoardReadOnlyRunContext,
    target: TaskBoardCodexLaunchTarget,
) {
    if target == TaskBoardCodexLaunchTarget::Local {
        variables.insert("worktree", context.worktree.clone());
    }
}

fn review_prompt(
    execution: &TaskBoardWorkflowExecutionRecord,
    context: &TaskBoardReadOnlyRunContext,
    attempt: &TaskBoardExecutionAttemptRecord,
    profile_id: &str,
    target: TaskBoardCodexLaunchTarget,
) -> Result<String, CliError> {
    let exact_head = exact_head(execution)?;
    let response = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: execution.execution_id.clone(),
        action_key: attempt.action_key.clone(),
        attempt: attempt.attempt,
        idempotency_key: attempt.idempotency_key.clone(),
        exact_head_revision: exact_head.to_string(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: profile_id.to_string(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: exact_head.to_string(),
                summary: "concise review conclusion".into(),
                findings: vec!["actionable finding when changes are required".into()],
            },
        }),
    };
    let pull_request = execution
        .transition
        .pull_request
        .as_ref()
        .map(|request| format!("{}#{}", request.repository, request.number));
    let mut variables = BTreeMap::from([
        ("board_item_id", execution.item_id.clone()),
        ("title", context.title.clone()),
        ("context", context.body.clone()),
        ("exact_head_revision", exact_head.to_string()),
        (
            "pull_request_line",
            pull_request
                .as_ref()
                .map_or_else(String::new, |request| format!("\nPull request: {request}")),
        ),
        ("workspace_directive", workspace_directive(context, target)),
        ("execution_id", execution.execution_id.clone()),
        ("managed_run_id", attempt.idempotency_key.clone()),
        ("profile_id", profile_id.to_string()),
        (
            "response_json",
            serde_json::to_string_pretty(&response).map_err(|error| {
                invalid_transition(format!("serialize review result template: {error}"))
            })?,
        ),
    ]);
    push_worktree(&mut variables, context, target);
    if let Some(pull_request) = pull_request {
        variables.insert("pull_request", pull_request);
    }
    render_prompt(PromptId::ReadOnlyReview, &variables)
}

fn evaluation_prompt(
    execution: &TaskBoardWorkflowExecutionRecord,
    context: &TaskBoardReadOnlyRunContext,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<String, CliError> {
    let exact_head = exact_head(execution)?;
    let write = matches!(
        execution.snapshot.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    );
    let response = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: execution.execution_id.clone(),
        action_key: attempt.action_key.clone(),
        attempt: attempt.attempt,
        idempotency_key: attempt.idempotency_key.clone(),
        exact_head_revision: exact_head.to_string(),
        artifact: TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
            verdict: TaskBoardPhaseVerdict::Pass,
            summary: "concise evaluation conclusion".into(),
            evidence: vec!["exact-head review evidence supporting the verdict".into()],
            head_revision: write.then(|| exact_head.to_string()),
            revision_cycle: write.then_some(execution.artifacts.current_revision_cycle),
        }),
    };
    let evidence = serde_json::to_string_pretty(&execution.artifacts.review_cycles)
        .map_err(|error| invalid_transition(format!("serialize review evidence: {error}")))?;
    let variables = BTreeMap::from([
        ("board_item_id", execution.item_id.clone()),
        ("title", context.title.clone()),
        ("exact_head_revision", exact_head.to_string()),
        ("review_evidence", evidence),
        ("execution_id", execution.execution_id.clone()),
        ("managed_run_id", attempt.idempotency_key.clone()),
        (
            "response_json",
            serde_json::to_string_pretty(&response).map_err(|error| {
                invalid_transition(format!("serialize evaluation result template: {error}"))
            })?,
        ),
    ]);
    render_prompt(PromptId::Evaluation, &variables)
}

fn read_only_capabilities(item_id: &str, tags: &[String], run_id: &str) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{item_id}"),
    ];
    capabilities.extend(tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities.push("task-board:workflow:read-only".into());
    capabilities.push(format!("task-board:attempt:{run_id}"));
    capabilities
}

fn write_capabilities(item_id: &str, tags: &[String], run_id: &str) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{item_id}"),
    ];
    capabilities.extend(tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities.push("task-board:workflow:write".into());
    capabilities.push(format!("task-board:attempt:{run_id}"));
    capabilities
}

fn workspace_directive(
    context: &TaskBoardReadOnlyRunContext,
    target: TaskBoardCodexLaunchTarget,
) -> String {
    match target {
        TaskBoardCodexLaunchTarget::Local => format!("Worktree: {}", context.worktree),
        TaskBoardCodexLaunchTarget::Remote => {
            "Workspace: use the isolated executor checkout assigned to this run".into()
        }
    }
}

pub(super) fn run_context(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<&TaskBoardReadOnlyRunContext, CliError> {
    let context = execution
        .snapshot
        .read_only_run_context
        .as_ref()
        .ok_or_else(|| invalid_transition("local workflow has no immutable run context"))?;
    validate_task_board_read_only_run_context(context)
        .map_err(|error| invalid_transition(error.to_string()))?;
    Ok(context)
}

fn exact_head(execution: &TaskBoardWorkflowExecutionRecord) -> Result<&str, CliError> {
    execution
        .transition
        .exact_head_revision
        .as_deref()
        .filter(|head| !head.trim().is_empty())
        .ok_or_else(|| invalid_transition("read-only workflow has no frozen exact head"))
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
