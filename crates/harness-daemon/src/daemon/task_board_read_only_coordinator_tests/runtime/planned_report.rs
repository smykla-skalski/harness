use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardEvaluationResult, TaskBoardPhaseVerdict,
    TaskBoardReportOnlyReviewFinding, TaskBoardReviewFindingLocation,
    TaskBoardReviewFindingSeverity, TaskBoardReviewResult, TaskBoardReviewerOutcome,
};

use super::super::fixture::FROZEN_HEAD;

pub(crate) struct PlannedReport {
    pub(super) action_key: String,
    pub(super) attempt: u32,
    pub(super) artifact: TaskBoardAttemptResultArtifact,
    pub(super) status: CodexRunStatus,
}

impl PlannedReport {
    pub(crate) fn passing_review() -> Self {
        Self::passing_review_for("reviewer-amber")
    }

    pub(crate) fn passing_review_for(profile_id: &str) -> Self {
        Self {
            action_key: format!("review:{profile_id}"),
            attempt: 1,
            artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
                profile_id: profile_id.into(),
                result: TaskBoardReviewResult {
                    verdict: TaskBoardPhaseVerdict::Pass,
                    head_revision: FROZEN_HEAD.into(),
                    summary: "exact-head review passed".into(),
                    findings: Vec::new(),
                    structured_findings: vec![TaskBoardReportOnlyReviewFinding {
                        severity: TaskBoardReviewFindingSeverity::High,
                        location: TaskBoardReviewFindingLocation {
                            path: "src/review.rs".into(),
                            line: Some(41),
                        },
                        evidence: "review finding retained".into(),
                    }],
                },
            }),
            status: CodexRunStatus::Completed,
        }
    }

    pub(crate) fn running_review() -> Self {
        let mut report = Self::passing_review();
        report.status = CodexRunStatus::Running;
        report
    }

    pub(crate) fn failed_review() -> Self {
        let mut report = Self::passing_review();
        report.status = CodexRunStatus::Failed;
        report
    }

    pub(crate) fn cancelled_review() -> Self {
        let mut report = Self::passing_review();
        report.status = CodexRunStatus::Cancelled;
        report
    }

    pub(crate) fn passing_evaluation() -> Self {
        Self {
            action_key: "evaluate".into(),
            attempt: 1,
            artifact: TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                summary: "durable review evidence passed evaluation".into(),
                evidence: vec!["review was bound to the frozen head".into()],
                head_revision: None,
                revision_cycle: None,
            }),
            status: CodexRunStatus::Completed,
        }
    }
}
