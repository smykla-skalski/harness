use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
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
    if execution.transition.phase == Some(TaskBoardExecutionPhase::Implementation) {
        write_implementation_request(execution, attempt)
    } else {
        codex_report_request(execution, attempt)
    }
}

pub(super) fn codex_report_request(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<CodexRunRequest, CliError> {
    let profile = attempt_profile(execution, attempt)?;
    let context = run_context(execution)?;
    let prompt = match execution.transition.phase {
        Some(TaskBoardExecutionPhase::Review) => {
            review_prompt(execution, context, attempt, &profile.id)?
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
) -> Result<CodexRunRequest, CliError> {
    let context = run_context(execution)?;
    let task_id = write_task_id(execution)?;
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: implementation_prompt(execution, context, attempt)?,
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
    Ok(format!(
        "Implement the exact approved plan for Task Board item '{}'.\n\nTitle: {}\nWorktree: {}\nBase head: {}\n\nApproved plan:\n{}\n\nAcceptance criteria:\n{}\n\nWork only in the assigned worktree. Preserve unrelated changes, run focused validation through repository workflows, and create local commits as required by the repository; do not push, publish, or merge. Before responding, replace every REPLACE_WITH_CURRENT_HEAD token below with the exact resulting Git HEAD. Your final message must contain only one JSON value matching this exact identity and shape:\n{}",
        execution.item_id,
        context.title,
        context.worktree,
        base_head,
        planning.plan_markdown,
        criteria,
        serde_json::to_string_pretty(&response).map_err(|error| {
            invalid_transition(format!("serialize implementation result template: {error}"))
        })?,
    ))
}

fn review_prompt(
    execution: &TaskBoardWorkflowExecutionRecord,
    context: &TaskBoardReadOnlyRunContext,
    attempt: &TaskBoardExecutionAttemptRecord,
    profile_id: &str,
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
        .map_or_else(String::new, |pr| {
            format!("\nPull request: {}#{}", pr.repository, pr.number)
        });
    Ok(format!(
        "Run a strictly read-only review for Task Board item '{}'.\n\nTitle: {}\nContext: {}\nExact head: {}{}\nWorktree: {}\n\nDo not modify files, commits, branches, task state, pull requests, or external systems. Verify that every inspected change belongs to the exact frozen head above; return human_required when that revision cannot be inspected. Your final message must contain only one JSON value matching this exact identity and shape (use verdict pass, changes_required, or human_required):\n{}",
        execution.item_id,
        context.title,
        context.body,
        exact_head,
        pull_request,
        context.worktree,
        serde_json::to_string_pretty(&response).map_err(|error| {
            invalid_transition(format!("serialize review result template: {error}"))
        })?,
    ))
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
    Ok(format!(
        "Evaluate the durable review evidence for Task Board item '{}'.\n\nTitle: {}\nExact head: {}\nReview evidence:\n{}\n\nDo not modify files, commits, branches, task state, pull requests, or external systems. Confirm the evidence is internally consistent and bound to the exact frozen head. Your final message must contain only one JSON value matching this exact identity and shape (use verdict pass, changes_required, or human_required):\n{}",
        execution.item_id,
        context.title,
        exact_head,
        evidence,
        serde_json::to_string_pretty(&response).map_err(|error| {
            invalid_transition(format!("serialize evaluation result template: {error}"))
        })?,
    ))
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
