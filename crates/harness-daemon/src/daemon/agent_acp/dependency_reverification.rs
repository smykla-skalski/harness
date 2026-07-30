use harness_agents::turn::{
    AgentTurnId, AgentTurnPullRequest, AgentTurnPullRequestContext, AgentTurnReadOnlyContent,
    AgentTurnRequest, AgentTurnResult, AgentTurnRuntime,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_task_board::{
    TASK_BOARD_DEPENDENCY_TRIAGE_MODEL, TaskBoardDependencyReverificationRequest,
    TaskBoardDependencyReverificationResult, parse_task_board_dependency_reverification_result,
    render_task_board_dependency_reverification_prompt,
    validate_task_board_dependency_reverification_request,
};

use super::OpenRouterAgentTurnRuntime;

impl OpenRouterAgentTurnRuntime {
    /// Resume the original dependency review context against one successful changed head.
    ///
    /// # Errors
    ///
    /// Returns an error when the evidence contract is inconsistent or `OpenRouter` cannot start
    /// the exact-head `DeepSeek` turn.
    pub async fn resume_dependency_reverification(
        &self,
        request: &TaskBoardDependencyReverificationRequest,
    ) -> Result<AgentTurnId, CliError> {
        let original_turn_id = AgentTurnId::new(&request.original_turn_id)?;
        let provider_session_id = self.runtime_session_id(&original_turn_id)?;
        self.start_with_resume_session(
            dependency_reverification_turn_request(request)?,
            Some(provider_session_id),
        )
        .await
    }

    /// Read and strictly validate one completed exact-head dependency reverification.
    ///
    /// # Errors
    ///
    /// Returns a fail-closed error for model drift, head drift, abnormal completion, malformed
    /// results, or a result that does not match the frozen reverification request.
    pub async fn dependency_reverification_result(
        &self,
        id: &AgentTurnId,
        request: &TaskBoardDependencyReverificationRequest,
    ) -> Result<Option<TaskBoardDependencyReverificationResult>, CliError> {
        let Some(result) = self.result(id).await? else {
            return Ok(None);
        };
        parse_completed_dependency_reverification(&result, request).map(Some)
    }
}

fn dependency_reverification_turn_request(
    request: &TaskBoardDependencyReverificationRequest,
) -> Result<AgentTurnRequest, CliError> {
    validate_task_board_dependency_reverification_request(request)?;
    let pull_request = AgentTurnPullRequest {
        repository: request.repository.clone(),
        number: request.pull_request_number,
        head_revision: request.exact_head_revision.clone(),
    };
    Ok(AgentTurnRequest {
        prompt: render_task_board_dependency_reverification_prompt(request)?,
        requested_model: Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL.into()),
        pull_request: Some(AgentTurnPullRequestContext {
            pull_request: pull_request.clone(),
            content: AgentTurnReadOnlyContent {
                pull_request,
                body: request.diff.clone(),
            },
        }),
    })
}

fn parse_completed_dependency_reverification(
    result: &AgentTurnResult,
    request: &TaskBoardDependencyReverificationRequest,
) -> Result<TaskBoardDependencyReverificationResult, CliError> {
    if result.stop_reason != "end_turn" {
        return Err(parse_error(
            "dependency reverification result did not end normally",
        ));
    }
    if result.requested_model.as_deref() != Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL)
        || result.effective_model.as_deref() != Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL)
        || result.source_revision.as_deref() != Some(request.exact_head_revision.as_str())
    {
        return Err(parse_error(
            "dependency reverification result is not bound to DeepSeek and the exact changed head",
        ));
    }
    parse_task_board_dependency_reverification_result(&result.report, request)
}

fn parse_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(detail.into()).into()
}

#[cfg(test)]
mod tests {
    use harness_task_board::github::{
        CheckGate, CheckState, Mergeability, PullRequestIdentity, PullRequestMergeGates,
        ReviewDecision, ReviewGate,
    };
    use harness_task_board::{
        TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
        TASK_BOARD_DEPENDENCY_REVERIFICATION_SCHEMA_VERSION,
        TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION, TaskBoardDependencyApprovalEvidence,
        TaskBoardDependencyCheck, TaskBoardDependencyCheckConclusion,
        TaskBoardDependencyCheckResumeRecord, TaskBoardDependencyCheckResumeStatus,
        TaskBoardDependencyCheckState, TaskBoardDependencyConflictEvidence,
        TaskBoardDependencyConflictState, TaskBoardDependencyFixAttemptPolicy,
        TaskBoardDependencyFixRequest, TaskBoardDependencyFixResult, TaskBoardDependencyIdentity,
        TaskBoardDependencyReverificationDecision, TaskBoardDependencySettledCheck,
        TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
        TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
        task_board_dependency_reverification_request,
    };

    use super::*;

    const ORIGINAL: &str = "0123456789abcdef0123456789abcdef01234567";
    const LOCAL: &str = "123456789abcdef0123456789abcdef012345678";
    const REMOTE: &str = "23456789abcdef0123456789abcdef0123456789";

    #[test]
    fn resumed_turn_contains_diff_context_model_and_exact_remote_head() {
        let request = request();
        let turn = dependency_reverification_turn_request(&request)
            .expect("turn request")
            .into_validated()
            .expect("validated turn");

        assert_eq!(
            turn.requested_model.as_deref(),
            Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL)
        );
        assert_eq!(
            turn.pull_request
                .as_ref()
                .map(|pull_request| pull_request.head_revision.as_str()),
            Some(REMOTE)
        );
        for expected in [
            "deepseek-turn-1",
            "diff --git a/Cargo.lock b/Cargo.lock",
            REMOTE,
            "\"current_gates\"",
        ] {
            assert!(turn.prompt.contains(expected), "missing {expected}");
        }
    }

    #[test]
    fn completed_result_is_model_request_and_exact_head_bound() {
        let request = request();
        let report = serde_json::to_string(&verification_result(&request)).expect("report");
        let result = AgentTurnResult {
            correlation_id: AgentTurnId::new("turn-2").expect("turn id"),
            report,
            stop_reason: "end_turn".into(),
            requested_model: Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL.into()),
            effective_model: Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL.into()),
            source_revision: Some(REMOTE.into()),
        };

        let parsed =
            parse_completed_dependency_reverification(&result, &request).expect("validated result");

        assert_eq!(
            parsed.decision,
            TaskBoardDependencyReverificationDecision::GreenLight
        );
    }

    #[test]
    fn abnormal_completion_or_head_drift_fails_closed() {
        let request = request();
        let mut result = AgentTurnResult {
            correlation_id: AgentTurnId::new("turn-2").expect("turn id"),
            report: serde_json::to_string(&verification_result(&request)).expect("report"),
            stop_reason: "max_tokens".into(),
            requested_model: Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL.into()),
            effective_model: Some(TASK_BOARD_DEPENDENCY_TRIAGE_MODEL.into()),
            source_revision: Some(REMOTE.into()),
        };
        assert!(parse_completed_dependency_reverification(&result, &request).is_err());

        result.stop_reason = "end_turn".into();
        result.source_revision = Some(LOCAL.into());
        assert!(parse_completed_dependency_reverification(&result, &request).is_err());
    }

    fn verification_result(
        request: &TaskBoardDependencyReverificationRequest,
    ) -> TaskBoardDependencyReverificationResult {
        TaskBoardDependencyReverificationResult {
            schema_version: TASK_BOARD_DEPENDENCY_REVERIFICATION_SCHEMA_VERSION,
            verification_id: request.verification_id.clone(),
            repository: request.repository.clone(),
            pull_request_number: request.pull_request_number,
            exact_head_revision: request.exact_head_revision.clone(),
            decision: TaskBoardDependencyReverificationDecision::GreenLight,
            reasoning: "the changed head is safe".into(),
            repair_instructions: Vec::new(),
        }
    }

    fn request() -> TaskBoardDependencyReverificationRequest {
        task_board_dependency_reverification_request(
            "deepseek-turn-1",
            &fixer_request(),
            &fixer_result(),
            &passed_ci(),
            &gates(),
            "diff --git a/Cargo.lock b/Cargo.lock\n+fixed",
        )
        .expect("reverification request")
    }

    fn fixer_request() -> TaskBoardDependencyFixRequest {
        TaskBoardDependencyFixRequest {
            dispatch_id: "route-1:fix".into(),
            route_id: "route-1".into(),
            session_id: "session-1".into(),
            board_item_id: "item-1".into(),
            workflow_execution_id: "execution-1".into(),
            attempt: 1,
            attempt_policy: TaskBoardDependencyFixAttemptPolicy::default(),
            repository: "acme/widgets".into(),
            pull_request_number: 17,
            exact_head_revision: ORIGINAL.into(),
            requested_repair: "repair".into(),
            triage_result: triage(),
            retry_evidence: None,
            audit: None,
        }
    }

    fn fixer_result() -> TaskBoardDependencyFixResult {
        TaskBoardDependencyFixResult {
            schema_version: TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
            dispatch_id: "route-1:fix".into(),
            route_id: "route-1".into(),
            base_head_revision: ORIGINAL.into(),
            head_revision: LOCAL.into(),
            summary: "fixed".into(),
            changed_paths: vec!["Cargo.lock".into()],
            validation: vec!["focused test passed".into()],
            remaining_blockers: Vec::new(),
        }
    }

    fn passed_ci() -> TaskBoardDependencyCheckResumeRecord {
        TaskBoardDependencyCheckResumeRecord {
            resume_id: "route-1:checks".into(),
            route_id: "route-1".into(),
            identity: PullRequestIdentity::from_slug("acme/widgets", 17),
            exact_head_revision: REMOTE.into(),
            status: TaskBoardDependencyCheckResumeStatus::ChecksPassed {
                checks: vec![TaskBoardDependencySettledCheck {
                    name: "build".into(),
                    conclusion: TaskBoardDependencyCheckConclusion::Success,
                    details_url: None,
                }],
            },
        }
    }

    fn gates() -> PullRequestMergeGates {
        PullRequestMergeGates {
            mergeability: Mergeability::Mergeable,
            viewer_can_update: true,
            viewer_can_merge_as_admin: false,
            checks: vec![CheckGate {
                name: "build".into(),
                state: CheckState::Success,
                details_url: None,
            }],
            required_check_names: vec!["build".into()],
            review: ReviewGate {
                decision: ReviewDecision::ReviewRequired,
                current_approvals: 0,
                required_approvals: 1,
            },
        }
    }

    fn triage() -> TaskBoardDependencyTriageResult {
        TaskBoardDependencyTriageResult {
            schema_version: TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
            repository: "acme/widgets".into(),
            pull_request_number: 17,
            exact_head_revision: ORIGINAL.into(),
            dependency: TaskBoardDependencyIdentity {
                name: "serde".into(),
                ecosystem: "cargo".into(),
                current_version: "1.0.200".into(),
                target_version: "1.0.201".into(),
                update_class: TaskBoardDependencyUpdateClass::Patch,
            },
            checks: vec![TaskBoardDependencyCheck {
                name: "build".into(),
                state: TaskBoardDependencyCheckState::Failed,
                details_url: None,
            }],
            conflicts: TaskBoardDependencyConflictEvidence {
                state: TaskBoardDependencyConflictState::Clean,
                summary: "clean".into(),
            },
            approvals: TaskBoardDependencyApprovalEvidence {
                current: 0,
                required: 1,
            },
            safety_assumption: "review the repair".into(),
            disposition: TaskBoardDependencyTriageDisposition::FixRequired,
            required_tools: vec!["task_board.audit".into(), "codex.dispatch".into()],
            next_steps: vec![
                TaskBoardDependencyTriageStep {
                    order: 1,
                    action: "record_result".into(),
                    reason: "retain review".into(),
                },
                TaskBoardDependencyTriageStep {
                    order: 2,
                    action: "dispatch_fixer".into(),
                    reason: "repair".into(),
                },
            ],
        }
    }
}
