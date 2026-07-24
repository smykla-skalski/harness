use serde::{Deserialize, Serialize};

use super::{TriageRuleSetV1, TriageRuleSetValidationReport};
use crate::task_board::triage::TriageVerdict;
use crate::task_board::triage_override::TaskBoardTriageEffectiveSource;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TriageRuleSetDraft {
    pub rules: TriageRuleSetV1,
    pub revision: i64,
    pub actor: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TriageRuleSetDraftSaveResult {
    pub validation: TriageRuleSetValidationReport,
    pub persisted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TriageRuleSetRevisionSummary {
    pub revision: i64,
    pub schema_version: u16,
    pub rule_count: usize,
    pub status: TriageRuleSetRevisionStatus,
    pub actor: String,
    pub activated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub superseded_at: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub enum TriageRuleSetRevisionStatus {
    Active,
    Superseded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TriageRuleSetAuditEntry {
    pub audit_id: String,
    pub kind: TriageRuleSetAuditKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<i64>,
    pub actor: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reevaluated_item_count: Option<i64>,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub enum TriageRuleSetAuditKind {
    Activated,
    ActivationRejected,
    Deactivated,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TriageRuleSetActivationResult {
    pub validation: TriageRuleSetValidationReport,
    pub activated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<i64>,
    pub reevaluated_item_count: usize,
}

/// Non-mutating evaluation of a candidate against one frozen read of the
/// current backlog -- never persists anything, whether or not the candidate
/// is valid.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TriageRuleSetPreviewResult {
    pub validation: TriageRuleSetValidationReport,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub diff: Vec<TriageRuleSetPreviewDiffEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TriageRuleSetPreviewDiffEntry {
    pub item_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live_effective_verdict: Option<TriageVerdict>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live_effective_source: Option<TaskBoardTriageEffectiveSource>,
    pub candidate_verdict: TriageVerdict,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate_matched_rule_id: Option<String>,
    /// Whether the item's actual governing outcome would change if this
    /// candidate were activated right now. Always `false` while an active
    /// human override governs placement -- the override keeps winning
    /// regardless of which automatic evaluator sits underneath it.
    pub governs_placement_change: bool,
}
