use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[IssueCodeMeta {
    code: IssueCode::UserFrustrationDetected,
    default_category: IssueCategory::UserFrustration,
    default_severity: IssueSeverity::Medium,
    default_confidence: Confidence::Low,
    default_fix_safety: FixSafety::AdvisoryOnly,
    description: "User frustration signal detected in message",
    owner: IssueOwner::Model,
}];
