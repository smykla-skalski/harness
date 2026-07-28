use super::super::IssueCodeMeta;
use super::super::{Confidence, FixSafety, IssueCategory, IssueCode, IssueOwner, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[
    IssueCodeMeta {
        code: IssueCode::HarnessCliErrorOutput,
        default_category: IssueCategory::CliError,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixSafe,
        description: "Harness CLI returned an error in command output",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::InvalidHarnessSubcommandUsed,
        default_category: IssueCategory::CliError,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixSafe,
        description: "Non-existent harness subcommand or argument used",
        owner: IssueOwner::Skill,
    },
    IssueCodeMeta {
        code: IssueCode::RunnerStateEventNotSupported,
        default_category: IssueCategory::CliError,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AutoFixSafe,
        description: "runner-state event transition not supported via CLI",
        owner: IssueOwner::Harness,
    },
];
