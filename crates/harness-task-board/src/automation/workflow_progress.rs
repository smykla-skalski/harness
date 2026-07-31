use std::{cmp::Ordering, collections::BTreeMap};

use chrono::DateTime;
use serde::{Deserialize, Serialize};

use super::{
    TaskBoardAttemptState, TaskBoardDependencyRouteRecord, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardTerminalOutcome, TaskBoardWorkflowExecutionRecord,
};
use crate::TaskBoardWorkflowKind;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardWorkflowAttemptRuntimeEvidence {
    pub runtime: String,
    pub model: Option<String>,
    pub report: Option<String>,
    pub terminal_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardWorkflowAttemptProgress {
    pub action_key: String,
    pub attempt: u32,
    pub state: TaskBoardAttemptState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_reason: Option<String>,
    pub started_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardWorkflowProgress {
    pub execution_id: String,
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<TaskBoardExecutionPhase>,
    pub state: TaskBoardExecutionState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exact_head_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_runtime: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub triage: Option<TaskBoardDependencyRouteRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_outcome: Option<TaskBoardTerminalOutcome>,
    pub attempts: Vec<TaskBoardWorkflowAttemptProgress>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardWorkflowProgressResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<TaskBoardWorkflowProgress>,
}

#[must_use]
pub fn build_task_board_workflow_progress(
    execution: &TaskBoardWorkflowExecutionRecord,
    runtime_evidence: &BTreeMap<String, TaskBoardWorkflowAttemptRuntimeEvidence>,
) -> TaskBoardWorkflowProgress {
    let attempts = execution
        .attempts
        .iter()
        .map(|attempt| {
            let evidence = runtime_evidence.get(&attempt.idempotency_key);
            TaskBoardWorkflowAttemptProgress {
                action_key: attempt.action_key.clone(),
                attempt: attempt.attempt,
                state: attempt.state,
                runtime: evidence.map(|value| value.runtime.clone()),
                model: evidence.and_then(|value| value.model.clone()),
                report: evidence
                    .and_then(|value| value.report.clone())
                    .or_else(|| attempt.artifact.as_ref().and_then(render_artifact)),
                terminal_reason: evidence
                    .and_then(|value| value.terminal_reason.clone())
                    .or_else(|| attempt.error.clone()),
                started_at: attempt.started_at.clone(),
                updated_at: attempt.updated_at.clone(),
                completed_at: attempt.completed_at.clone(),
            }
        })
        .collect::<Vec<_>>();
    let current = attempts
        .iter()
        .max_by(|left, right| compare_attempt_recency(left, right));

    TaskBoardWorkflowProgress {
        execution_id: execution.execution_id.clone(),
        workflow_kind: execution.transition.workflow_kind,
        phase: execution.transition.phase,
        state: execution.transition.execution_state,
        exact_head_revision: execution.transition.exact_head_revision.clone(),
        current_runtime: current.and_then(|attempt| attempt.runtime.clone()),
        current_model: current.and_then(|attempt| attempt.model.clone()),
        blocked_reason: execution.blocked_reason.clone(),
        triage: execution.artifacts.dependency_triage.clone(),
        terminal_outcome: execution.artifacts.terminal_outcome.clone(),
        attempts,
        created_at: execution.created_at.clone(),
        updated_at: execution.updated_at.clone(),
        completed_at: execution.completed_at.clone(),
    }
}

fn compare_attempt_recency(
    left: &TaskBoardWorkflowAttemptProgress,
    right: &TaskBoardWorkflowAttemptProgress,
) -> Ordering {
    let timestamp_order = match (
        DateTime::parse_from_rfc3339(&left.updated_at),
        DateTime::parse_from_rfc3339(&right.updated_at),
    ) {
        (Ok(left), Ok(right)) => left.cmp(&right),
        _ => left.updated_at.cmp(&right.updated_at),
    };
    timestamp_order
        .then_with(|| left.attempt.cmp(&right.attempt))
        .then_with(|| left.action_key.cmp(&right.action_key))
}

fn render_artifact(artifact: &super::TaskBoardAttemptResultArtifact) -> Option<String> {
    serde_json::to_string_pretty(artifact).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership, TaskBoardResolvedReviewer,
        TaskBoardReviewerProfile, TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowSnapshot,
        TaskBoardWorkflowTransitionState,
    };

    #[test]
    fn progress_joins_runtime_report_and_terminal_reason() {
        let execution = execution();
        let mut evidence = BTreeMap::new();
        evidence.insert(
            "run-1".into(),
            TaskBoardWorkflowAttemptRuntimeEvidence {
                runtime: "openrouter".into(),
                model: Some("deepseek/deepseek-v4-flash".into()),
                report: Some("Exact-head triage completed.".into()),
                terminal_reason: Some("required check failed".into()),
            },
        );

        let progress = build_task_board_workflow_progress(&execution, &evidence);

        assert_eq!(progress.current_runtime.as_deref(), Some("openrouter"));
        assert_eq!(
            progress.current_model.as_deref(),
            Some("deepseek/deepseek-v4-flash")
        );
        assert_eq!(
            progress.attempts[0].report.as_deref(),
            Some("Exact-head triage completed.")
        );
        assert_eq!(
            progress.attempts[0].terminal_reason.as_deref(),
            Some("required check failed")
        );
    }

    #[test]
    fn current_runtime_uses_most_recent_attempt() {
        let mut execution = execution();
        let mut older_attempt = execution.attempts[0].clone();
        older_attempt.action_key = "z_cleanup".into();
        older_attempt.idempotency_key = "run-older".into();
        older_attempt.updated_at = "2026-07-30T08:00:00Z".into();
        older_attempt.completed_at = Some("2026-07-30T08:00:00Z".into());
        execution.attempts.push(older_attempt);
        let evidence = BTreeMap::from([
            (
                "run-1".into(),
                TaskBoardWorkflowAttemptRuntimeEvidence {
                    runtime: "codex".into(),
                    model: Some("gpt-5.3-codex-spark".into()),
                    report: None,
                    terminal_reason: None,
                },
            ),
            (
                "run-older".into(),
                TaskBoardWorkflowAttemptRuntimeEvidence {
                    runtime: "openrouter".into(),
                    model: Some("deepseek/deepseek-v4-flash".into()),
                    report: None,
                    terminal_reason: None,
                },
            ),
        ]);

        let progress = build_task_board_workflow_progress(&execution, &evidence);

        assert_eq!(progress.current_runtime.as_deref(), Some("codex"));
        assert_eq!(
            progress.current_model.as_deref(),
            Some("gpt-5.3-codex-spark")
        );
    }

    #[test]
    fn current_runtime_breaks_timestamp_ties_by_attempt() {
        let mut execution = execution();
        let mut later_attempt = execution.attempts[0].clone();
        later_attempt.attempt = 2;
        later_attempt.idempotency_key = "run-2".into();
        execution.attempts.push(later_attempt);
        let evidence = evidence_for_two_attempts();

        let progress = build_task_board_workflow_progress(&execution, &evidence);

        assert_eq!(progress.current_runtime.as_deref(), Some("openrouter"));
    }

    #[test]
    fn current_runtime_breaks_attempt_ties_by_action_key() {
        let mut execution = execution();
        let mut later_action = execution.attempts[0].clone();
        later_action.action_key = "review:zeta".into();
        later_action.idempotency_key = "run-2".into();
        execution.attempts.push(later_action);
        let evidence = evidence_for_two_attempts();

        let progress = build_task_board_workflow_progress(&execution, &evidence);

        assert_eq!(progress.current_runtime.as_deref(), Some("openrouter"));
    }

    #[test]
    fn current_runtime_orders_legacy_timestamps_deterministically() {
        let mut execution = execution();
        execution.attempts[0].updated_at = "legacy-1".into();
        let mut later_attempt = execution.attempts[0].clone();
        later_attempt.attempt = 2;
        later_attempt.idempotency_key = "run-2".into();
        later_attempt.updated_at = "legacy-2".into();
        execution.attempts.push(later_attempt);
        let evidence = evidence_for_two_attempts();

        let progress = build_task_board_workflow_progress(&execution, &evidence);

        assert_eq!(progress.current_runtime.as_deref(), Some("openrouter"));
    }

    fn evidence_for_two_attempts() -> BTreeMap<String, TaskBoardWorkflowAttemptRuntimeEvidence> {
        BTreeMap::from([
            (
                "run-1".into(),
                TaskBoardWorkflowAttemptRuntimeEvidence {
                    runtime: "codex".into(),
                    model: None,
                    report: None,
                    terminal_reason: None,
                },
            ),
            (
                "run-2".into(),
                TaskBoardWorkflowAttemptRuntimeEvidence {
                    runtime: "openrouter".into(),
                    model: None,
                    report: None,
                    terminal_reason: None,
                },
            ),
        ])
    }

    fn execution() -> TaskBoardWorkflowExecutionRecord {
        TaskBoardWorkflowExecutionRecord {
            execution_id: "execution-1".into(),
            item_id: "item-1".into(),
            snapshot: TaskBoardWorkflowSnapshot {
                workflow_kind: TaskBoardWorkflowKind::Review,
                execution_repository: Some("example/harness".into()),
                item_revision: 1,
                configuration_revision: 1,
                policy_version: "policy-v1".into(),
                reviewer: TaskBoardResolvedReviewer {
                    reviewer_count: 0,
                    required_approvals: 0,
                    max_revision_cycles: 1,
                    profiles: Vec::<TaskBoardReviewerProfile>::new(),
                },
                read_only_run_context: None,
                provider_revision: None,
            },
            resolved_reviewers: TaskBoardResolvedReviewer {
                reviewer_count: 0,
                required_approvals: 0,
                max_revision_cycles: 1,
                profiles: Vec::new(),
            },
            transition: TaskBoardWorkflowTransitionState {
                workflow_kind: TaskBoardWorkflowKind::Review,
                phase: Some(TaskBoardExecutionPhase::Review),
                execution_state: TaskBoardExecutionState::Running,
                pull_request: None,
                exact_head_revision: Some("0123456789abcdef0123456789abcdef01234567".into()),
            },
            artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
            ownership: TaskBoardExecutionOwnership::default(),
            available_at: None,
            blocked_reason: None,
            created_at: "2026-07-30T08:00:00Z".into(),
            updated_at: "2026-07-30T08:01:00Z".into(),
            completed_at: None,
            attempts: vec![TaskBoardExecutionAttemptRecord {
                execution_id: "execution-1".into(),
                action_key: "dependency_triage".into(),
                attempt: 1,
                idempotency_key: "run-1".into(),
                state: TaskBoardAttemptState::Failed,
                failure_class: None,
                available_at: None,
                error: Some("fallback error".into()),
                artifact: None,
                started_at: "2026-07-30T08:00:00Z".into(),
                updated_at: "2026-07-30T08:01:00Z".into(),
                completed_at: Some("2026-07-30T08:01:00Z".into()),
            }],
        }
    }
}
