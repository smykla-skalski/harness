use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[
    IssueCodeMeta {
        code: IssueCode::BuildOrLintFailure,
        default_category: IssueCategory::BuildError,
        default_severity: IssueSeverity::Critical,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixSafe,
        description: "Rust build or clippy lint failure",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::PythonTracebackOutput,
        default_category: IssueCategory::BuildError,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixGuarded,
        description: "Python traceback in command output",
        owner: IssueOwner::Model,
    },
];
