use std::collections::BTreeMap;

use crate::daemon::agent_tui::AgentTuiStartRequest;
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use crate::errors::CliError;
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::prompt_catalog::{PromptId, render_prompt};
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
    TaskBoardAttemptResultArtifact, TaskBoardImplementationResult, TaskBoardItem,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReadOnlyWorkflowLaunch,
    TaskBoardReviewResult, TaskBoardReviewerOutcome, TaskBoardWriteWorkflowLaunch,
    WorkerPromptContext, render_worker_prompt,
};

const DEFAULT_INTERACTIVE_RUNTIME: &str = "codex";

/// Build the Codex run request for one dispatched item.
///
/// # Errors
/// Returns an error when the configured prompt cannot be rendered for this
/// item, refusing the spawn before the agent starts.
pub(crate) fn codex_worker_request(
    applied: &DispatchAppliedTask,
    managed_run_id: &str,
) -> Result<CodexRunRequest, CliError> {
    if let Some(launch) = applied.read_only_workflow.as_ref() {
        return read_only_review_request(applied, launch, managed_run_id);
    }
    if let Some(launch) = applied.write_workflow.as_ref() {
        return write_implementation_request(applied, launch, managed_run_id);
    }
    let mode = match applied.item.agent_mode {
        AgentMode::Planning | AgentMode::Evaluate => CodexRunMode::Report,
        AgentMode::Headless | AgentMode::Interactive => CodexRunMode::WorkspaceWrite,
    };
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: worker_prompt(applied, managed_run_id)?,
        mode,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: worker_capabilities(&applied.item),
        name: Some(worker_name(&applied.item)),
        persona: None,
        resume_thread_id: None,
        task_id: Some(applied.work_item_id.clone()),
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: None,
        effort: None,
        allow_custom_model: false,
    })
}

fn write_implementation_request(
    applied: &DispatchAppliedTask,
    launch: &TaskBoardWriteWorkflowLaunch,
    managed_run_id: &str,
) -> Result<CodexRunRequest, CliError> {
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: write_implementation_prompt(applied, launch, managed_run_id)?,
        mode: CodexRunMode::WorkspaceWrite,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: write_capabilities(
            &applied.board_item_id,
            &launch.run_context.tags,
            managed_run_id,
        ),
        name: Some(format!(
            "Task Board Implementation: {}",
            launch.run_context.title
        )),
        persona: None,
        resume_thread_id: None,
        task_id: Some(launch.task_id.clone()),
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: None,
        effort: None,
        allow_custom_model: false,
    })
}

fn write_implementation_prompt(
    applied: &DispatchAppliedTask,
    launch: &TaskBoardWriteWorkflowLaunch,
    managed_run_id: &str,
) -> Result<String, CliError> {
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .expect("write prompt requires workflow execution id");
    let response = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: execution_id.to_string(),
        action_key: "implementation:1".into(),
        attempt: 1,
        idempotency_key: managed_run_id.to_string(),
        exact_head_revision: "REPLACE_WITH_CURRENT_HEAD".into(),
        artifact: TaskBoardAttemptResultArtifact::Implementation(TaskBoardImplementationResult {
            revision_cycle: 1,
            base_head_revision: launch.base_head_revision.clone(),
            head_revision: "REPLACE_WITH_CURRENT_HEAD".into(),
            summary: "concise implementation summary".into(),
            evidence: vec!["focused validation and owning gate results".into()],
        }),
    };
    let criteria = launch
        .planning_result
        .acceptance_criteria
        .iter()
        .map(|criterion| format!("- {criterion}"))
        .collect::<Vec<_>>()
        .join("\n");
    let variables = BTreeMap::from([
        ("board_item_id", applied.board_item_id.clone()),
        ("title", launch.run_context.title.clone()),
        ("worktree", launch.run_context.worktree.clone()),
        (
            "workspace_directive",
            format!("Worktree: {}", launch.run_context.worktree),
        ),
        ("base_head_revision", launch.base_head_revision.clone()),
        (
            "plan_markdown",
            launch.planning_result.plan_markdown.clone(),
        ),
        ("acceptance_criteria", criteria),
        ("execution_id", execution_id.to_string()),
        ("managed_run_id", managed_run_id.to_string()),
        (
            "response_json",
            serde_json::to_string_pretty(&response)
                .expect("serialize implementation response template"),
        ),
    ]);
    render_prompt(PromptId::WriteImplementation, &variables)
}

fn read_only_review_request(
    applied: &DispatchAppliedTask,
    launch: &TaskBoardReadOnlyWorkflowLaunch,
    managed_run_id: &str,
) -> Result<CodexRunRequest, CliError> {
    let profile = launch
        .resolved_reviewers
        .profiles
        .first()
        .expect("validated read-only launch has a reviewer profile");
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: read_only_review_prompt(applied, profile.id.as_str(), managed_run_id)?,
        mode: CodexRunMode::Report,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: read_only_capabilities(
            &applied.board_item_id,
            &launch.run_context.tags,
            managed_run_id,
        ),
        name: Some(format!("Task Board Review: {}", launch.run_context.title)),
        persona: Some(profile.persona.clone()),
        resume_thread_id: None,
        task_id: None,
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: profile.model.clone(),
        effort: profile.effort.clone(),
        allow_custom_model: false,
    })
}

fn read_only_review_prompt(
    applied: &DispatchAppliedTask,
    profile_id: &str,
    managed_run_id: &str,
) -> Result<String, CliError> {
    let launch = applied
        .read_only_workflow
        .as_ref()
        .expect("read-only prompt requires frozen launch");
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .expect("read-only prompt requires workflow execution id");
    let action_key = format!("review:{profile_id}");
    let pull_request = launch
        .pull_request
        .as_ref()
        .map(|request| format!("{}#{}", request.repository, request.number));
    let response = TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: execution_id.to_string(),
        action_key,
        attempt: 1,
        idempotency_key: managed_run_id.to_string(),
        exact_head_revision: launch.exact_head_revision.clone(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: profile_id.to_string(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: launch.exact_head_revision.clone(),
                summary: "concise review conclusion".into(),
                findings: vec!["actionable finding when changes are required".into()],
            },
        }),
    };
    let mut variables = BTreeMap::from([
        ("board_item_id", applied.board_item_id.clone()),
        ("title", launch.run_context.title.clone()),
        ("context", launch.run_context.body.clone()),
        (
            "exact_head_revision",
            launch.exact_head_revision.clone(),
        ),
        (
            "pull_request_line",
            pull_request
                .as_ref()
                .map_or_else(String::new, |request| format!("\nPull request: {request}")),
        ),
        ("worktree", launch.run_context.worktree.clone()),
        (
            "workspace_directive",
            format!("Worktree: {}", launch.run_context.worktree),
        ),
        ("execution_id", execution_id.to_string()),
        ("managed_run_id", managed_run_id.to_string()),
        ("profile_id", profile_id.to_string()),
        (
            "response_json",
            serde_json::to_string_pretty(&response).expect("serialize review response template"),
        ),
    ]);
    if let Some(pull_request) = pull_request {
        variables.insert("pull_request", pull_request);
    }
    render_prompt(PromptId::ReadOnlyReview, &variables)
}

/// Build the terminal worker start request for one dispatched item.
///
/// # Errors
/// Returns an error when the configured prompt cannot be rendered for this
/// item, refusing the spawn before the agent starts.
pub(super) fn terminal_worker_request(
    applied: &DispatchAppliedTask,
    managed_run_id: &str,
) -> Result<AgentTuiStartRequest, CliError> {
    Ok(AgentTuiStartRequest {
        runtime: DEFAULT_INTERACTIVE_RUNTIME.to_string(),
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: worker_capabilities(&applied.item),
        name: Some(worker_name(&applied.item)),
        prompt: Some(worker_prompt(applied, managed_run_id)?),
        project_dir: None,
        argv: Vec::new(),
        rows: 24,
        cols: 80,
        persona: None,
        task_id: Some(applied.work_item_id.clone()),
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: None,
        effort: None,
        allow_custom_model: false,
    })
}

fn worker_name(item: &TaskBoardItem) -> String {
    format!("Task Board: {}", item.title)
}

fn worker_capabilities(item: &TaskBoardItem) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{}", item.id),
    ];
    capabilities.extend(item.tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities
}

fn read_only_capabilities(item_id: &str, tags: &[String], managed_run_id: &str) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{item_id}"),
    ];
    capabilities.extend(tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities.push("task-board:workflow:read-only".into());
    capabilities.push(format!("task-board:attempt:{managed_run_id}"));
    capabilities
}

fn write_capabilities(item_id: &str, tags: &[String], managed_run_id: &str) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{item_id}"),
    ];
    capabilities.extend(tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities.push("task-board:workflow:write".into());
    capabilities.push(format!("task-board:attempt:{managed_run_id}"));
    capabilities
}

/// Render the ordinary worker prompt for one dispatched item.
///
/// # Errors
/// Returns an error when the configured prompt cannot be rendered for this
/// item.
pub(super) fn worker_prompt(
    applied: &DispatchAppliedTask,
    managed_run_id: &str,
) -> Result<String, CliError> {
    render_worker_prompt(
        &applied.item,
        &WorkerPromptContext {
            board_item_id: &applied.board_item_id,
            work_item_id: &applied.work_item_id,
            worktree: applied.item.workflow.worktree.as_deref(),
            session_id: Some(&applied.session_id),
            managed_run_id: Some(managed_run_id),
            status: applied.item.status,
        },
    )
}
