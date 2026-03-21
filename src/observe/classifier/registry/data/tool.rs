use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[IssueCodeMeta {
    code: IssueCode::ToolUsageErrorOutput,
    default_category: IssueCategory::ToolError,
    default_severity: IssueSeverity::Low,
    default_confidence: Confidence::High,
    default_fix_safety: FixSafety::AdvisoryOnly,
    description: "Claude tool usage error in output",
    owner: IssueOwner::Model,
}];
