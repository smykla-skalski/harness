use crate::observe::classifier::registry::{IssueCodeMeta, IssueOwner};
use crate::observe::types::{Confidence, FixSafety, IssueCategory, IssueCode, IssueSeverity};

pub(super) static ISSUE_CODE_METAS: &[IssueCodeMeta] = &[
    IssueCodeMeta {
        code: IssueCode::AgentStalledProgress,
        default_category: IssueCategory::AgentCoordination,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::Medium,
        default_fix_safety: FixSafety::TriageRequired,
        description: "Agent has not made tool calls for an extended period",
        owner: IssueOwner::Model,
    },
    IssueCodeMeta {
        code: IssueCode::AgentRepeatedError,
        default_category: IssueCategory::AgentCoordination,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::TriageRequired,
        description: "Same error pattern detected across multiple agents",
        owner: IssueOwner::Model,
    },
    IssueCodeMeta {
        code: IssueCode::AgentGuardDenialLoop,
        default_category: IssueCategory::AgentCoordination,
        default_severity: IssueSeverity::Critical,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::TriageRequired,
        description: "Agent repeatedly hitting guard denials",
        owner: IssueOwner::Model,
    },
    IssueCodeMeta {
        code: IssueCode::ApiRateLimitDetected,
        default_category: IssueCategory::AgentCoordination,
        default_severity: IssueSeverity::Critical,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::AdvisoryOnly,
        description: "API rate limit or overload error detected in tool output",
        owner: IssueOwner::Harness,
    },
    IssueCodeMeta {
        code: IssueCode::AgentSkillMisuse,
        default_category: IssueCategory::AgentCoordination,
        default_severity: IssueSeverity::Medium,
        default_confidence: Confidence::Medium,
        default_fix_safety: FixSafety::TriageRequired,
        description: "Agent using wrong skill for its assigned task",
        owner: IssueOwner::Model,
    },
    IssueCodeMeta {
        code: IssueCode::CrossAgentFileConflict,
        default_category: IssueCategory::AgentCoordination,
        default_severity: IssueSeverity::Critical,
        default_confidence: Confidence::High,
        default_fix_safety: FixSafety::TriageRequired,
        description: "Multiple agents editing the same file concurrently",
        owner: IssueOwner::Harness,
    },
];
