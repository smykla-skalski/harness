use async_trait::async_trait;
use harness_kernel::errors::CliError;
use harness_task_board::{
    TASK_BOARD_DEPENDENCY_FIXER_EFFORT, TASK_BOARD_DEPENDENCY_FIXER_MODEL,
    TaskBoardDependencyFixLauncher, TaskBoardDependencyFixRequest, TaskBoardDependencyFixRun,
    render_task_board_dependency_fix_prompt,
};

use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};

use super::CodexControllerHandle;

#[derive(Clone)]
pub struct CodexDependencyFixLauncher {
    controller: CodexControllerHandle,
}

impl CodexDependencyFixLauncher {
    #[must_use]
    pub fn new(controller: CodexControllerHandle) -> Self {
        Self { controller }
    }
}

#[async_trait]
impl TaskBoardDependencyFixLauncher for CodexDependencyFixLauncher {
    async fn start(
        &self,
        request: &TaskBoardDependencyFixRequest,
    ) -> Result<TaskBoardDependencyFixRun, CliError> {
        let codex_request = dependency_fix_codex_request(request)?;
        let snapshot = self.controller.start_run_with_id(
            &request.session_id,
            &codex_request,
            request.dispatch_id.clone(),
        )?;
        Ok(TaskBoardDependencyFixRun {
            run_id: snapshot.run_id,
            runtime: "codex".into(),
            requested_model: snapshot
                .model
                .unwrap_or_else(|| TASK_BOARD_DEPENDENCY_FIXER_MODEL.into()),
            requested_effort: snapshot
                .effort
                .unwrap_or_else(|| TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into()),
        })
    }
}

fn dependency_fix_codex_request(
    request: &TaskBoardDependencyFixRequest,
) -> Result<CodexRunRequest, CliError> {
    Ok(CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: render_task_board_dependency_fix_prompt(request)?,
        mode: CodexRunMode::WorkspaceWrite,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: vec![
            "task-board".into(),
            format!("task-board:item:{}", request.board_item_id),
            "task-board:workflow:write".into(),
            format!("task-board:attempt:{}", request.dispatch_id),
        ],
        name: Some(format!(
            "Dependency Fix: {}#{}",
            request.repository, request.pull_request_number
        )),
        persona: None,
        resume_thread_id: None,
        task_id: None,
        board_item_id: Some(request.board_item_id.clone()),
        workflow_execution_id: Some(request.workflow_execution_id.clone()),
        model: Some(TASK_BOARD_DEPENDENCY_FIXER_MODEL.into()),
        effort: Some(TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into()),
        allow_custom_model: false,
    })
}

#[cfg(test)]
mod tests {
    use harness_task_board::{
        TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck,
        TaskBoardDependencyCheckState, TaskBoardDependencyConflictEvidence,
        TaskBoardDependencyConflictState, TaskBoardDependencyIdentity,
        TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
        TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
    };

    use super::*;

    const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn codex_request_is_write_scoped_and_pinned_to_mini_low() {
        let request = dependency_fix_request();
        let codex = dependency_fix_codex_request(&request).expect("Codex request");

        assert_eq!(codex.mode, CodexRunMode::WorkspaceWrite);
        assert_eq!(
            codex.model.as_deref(),
            Some(TASK_BOARD_DEPENDENCY_FIXER_MODEL)
        );
        assert_eq!(
            codex.effort.as_deref(),
            Some(TASK_BOARD_DEPENDENCY_FIXER_EFFORT)
        );
        assert_eq!(codex.board_item_id.as_deref(), Some("item-1"));
        assert_eq!(codex.workflow_execution_id.as_deref(), Some("execution-1"));
        assert!(codex.prompt.contains(HEAD));
        assert!(codex.prompt.contains("\"checks\""));
    }

    fn dependency_fix_request() -> TaskBoardDependencyFixRequest {
        TaskBoardDependencyFixRequest {
            dispatch_id: "route-1:fix".into(),
            route_id: "route-1".into(),
            session_id: "session-1".into(),
            board_item_id: "item-1".into(),
            workflow_execution_id: "execution-1".into(),
            repository: "acme/widgets".into(),
            pull_request_number: 17,
            exact_head_revision: HEAD.into(),
            requested_repair: "repair the failing build".into(),
            triage_result: TaskBoardDependencyTriageResult {
                schema_version: 1,
                repository: "acme/widgets".into(),
                pull_request_number: 17,
                exact_head_revision: HEAD.into(),
                dependency: TaskBoardDependencyIdentity {
                    name: "serde".into(),
                    ecosystem: "cargo".into(),
                    current_version: "1.0.0".into(),
                    target_version: "1.0.1".into(),
                    update_class: TaskBoardDependencyUpdateClass::Patch,
                },
                checks: vec![TaskBoardDependencyCheck {
                    name: "test".into(),
                    state: TaskBoardDependencyCheckState::Failed,
                    details_url: Some("https://example.test/check/1".into()),
                }],
                conflicts: TaskBoardDependencyConflictEvidence {
                    state: TaskBoardDependencyConflictState::Clean,
                    summary: "clean".into(),
                },
                approvals: TaskBoardDependencyApprovalEvidence {
                    current: 1,
                    required: 1,
                },
                safety_assumption: "the exact-head evidence is current".into(),
                disposition: TaskBoardDependencyTriageDisposition::FixRequired,
                required_tools: vec!["task_board.audit".into(), "codex.dispatch".into()],
                next_steps: vec![
                    TaskBoardDependencyTriageStep {
                        order: 1,
                        action: "record_result".into(),
                        reason: "retain the triage decision".into(),
                    },
                    TaskBoardDependencyTriageStep {
                        order: 2,
                        action: "dispatch_fixer".into(),
                        reason: "repair the failing build".into(),
                    },
                ],
            },
        }
    }
}
