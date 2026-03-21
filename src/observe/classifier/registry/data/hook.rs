use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[
    IssueCodeMeta {
        code: IssueCode::HookDeniedToolCall,
        default_category: IssueCategory::HookFailure,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::TriageRequired,
        description: "Hook denied a tool call",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::HarnessHookCodeTriggered,
        default_category: IssueCategory::HookFailure,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixSafe,
        description: "Harness hook code (KSA/KSR) triggered in output",
        owner: IssueOwner::Harness,
    },
];
