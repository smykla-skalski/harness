use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[
    IssueCodeMeta {
        code: IssueCode::WorkflowStateErrorOutput,
        default_category: IssueCategory::WorkflowError,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixGuarded,
        description: "Workflow state machine error in output",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::HarnessCreateCommandFailure,
        default_category: IssueCategory::WorkflowError,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixGuarded,
        description: "Harness create command returned non-zero exit",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::CloseoutVerdictPending,
        default_category: IssueCategory::WorkflowError,
        default_severity: IssueSeverity::Critical,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixSafe,
        description: "Closeout blocked because no final verdict was set",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::RunnerStateMachineStale,
        default_category: IssueCategory::WorkflowError,
        default_severity: IssueSeverity::Critical,
        default_confidence: Confidence::Medium,
        default_fix_safety: FixSafety::AutoFixGuarded,
        description: "Runner state machine never advanced past bootstrap",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::HarnessInfrastructureMisconfiguration,
        default_category: IssueCategory::WorkflowError,
        default_severity: IssueSeverity::Critical,
        default_confidence: Confidence::Medium,
        default_fix_safety: FixSafety::TriageRequired,
        description: "Harness infrastructure misconfiguration detected",
        owner: IssueOwner::Harness,
    },
];
