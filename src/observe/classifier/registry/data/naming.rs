use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[IssueCodeMeta {
    code: IssueCode::OldSkillNameUsedInCommand,
    default_category: IssueCategory::NamingError,
    default_severity: IssueSeverity::Medium,
    default_confidence: Confidence::High,
    default_fix_safety: FixSafety::AutoFixSafe,
    description: "Old skill name (suite-author/suite-runner) used in command",
    owner: IssueOwner::Skill,
}];
