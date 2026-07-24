use serde::{Deserialize, Serialize};

use crate::task_board::{
    TriageRuleSetAuditEntry, TriageRuleSetDraft, TriageRuleSetRevisionSummary, TriageRuleSetV1,
};

pub const TASK_BOARD_TRIAGE_RULES_LIST_DEFAULT_LIMIT: u32 = 50;

/// Response for `GET /v1/task-board/triage/rules/draft`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskBoardTriageRulesDraftResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub draft: Option<TriageRuleSetDraft>,
}

/// Request for `PUT /v1/task-board/triage/rules/draft`. `expected_revision`
/// is `None` when saving over an empty slot (no draft yet).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskBoardSaveTriageRulesDraftRequest {
    pub rules: TriageRuleSetV1,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_revision: Option<i64>,
    /// Bound to the authenticated control-plane principal at the transport edge.
    #[serde(default)]
    pub actor: String,
}

/// Request for `POST /v1/task-board/triage/rules/preview`. Never persists
/// anything, whether or not `rules` is valid.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskBoardPreviewTriageRulesRequest {
    pub rules: TriageRuleSetV1,
}

/// Request for `POST /v1/task-board/triage/rules/activate`. `rules: None`
/// deactivates back to the `BuiltInV1` default; `expected_active_revision`
/// is `None` when no custom rule set currently governs.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskBoardActivateTriageRulesRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rules: Option<TriageRuleSetV1>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_active_revision: Option<i64>,
    /// Bound to the authenticated control-plane principal at the transport edge.
    #[serde(default)]
    pub actor: String,
}

/// Response for `GET /v1/task-board/triage/rules/revisions`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskBoardTriageRulesRevisionsResponse {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub revisions: Vec<TriageRuleSetRevisionSummary>,
}

/// Response for `GET /v1/task-board/triage/rules/audit`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct TaskBoardTriageRulesAuditResponse {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub audit: Vec<TriageRuleSetAuditEntry>,
}
