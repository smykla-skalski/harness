use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[
    IssueCodeMeta {
        code: IssueCode::NonZeroExitCode,
        default_category: IssueCategory::SubagentIssue,
        default_severity: IssueSeverity::Low,
        default_confidence: Confidence::Medium,
        default_fix_safety: FixSafety::AdvisoryOnly,
        description: "Non-zero exit code from a command",
        owner: IssueOwner::Model,
    },
    IssueCodeMeta {
        code: IssueCode::SubagentPermissionFailure,
        default_category: IssueCategory::SubagentIssue,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixSafe,
        description: "Subagent blocked by missing permissions",
        owner: IssueOwner::Skill,
    },
    IssueCodeMeta {
        code: IssueCode::SubagentManualRecovery,
        default_category: IssueCategory::SubagentIssue,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::Medium,
        default_fix_safety: FixSafety::AutoFixGuarded,
        description: "Subagent required manual recovery after save failure",
        owner: IssueOwner::Skill,
    },
    IssueCodeMeta {
        code: IssueCode::ManualPayloadRecovery,
        default_category: IssueCategory::SubagentIssue,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::Low,
        default_fix_safety: FixSafety::AdvisoryOnly,
        description: "Manual payload recovery from subagent output via grep",
        owner: IssueOwner::Skill,
    },
    IssueCodeMeta {
        code: IssueCode::IncompleteWriterOutput,
        default_category: IssueCategory::SubagentIssue,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::Medium,
        default_fix_safety: FixSafety::AutoFixGuarded,
        description: "Writer subagent produced incomplete output",
        owner: IssueOwner::Skill,
    },
];
