use serde::{Deserialize, Serialize};

use crate::task_board::TriageVerdict;

/// Request body for `POST /v1/task-board/triage/escalations/{escalation_id}/verdict`.
/// HTTP-only, never exposed to remote or Swift clients (see the route
/// catalog's `Exempt` classification for this path) -- the only caller is
/// the daemon's own spawned escalation worker, via the
/// `harness task-board triage-escalation report` CLI subcommand.
/// `verdict_token` is the single-use credential minted when the executor
/// claimed this escalation; it is the entire authentication for this
/// endpoint, not the control-plane session.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardTriageEscalationVerdictRequest {
    pub verdict_token: String,
    pub evidence_fingerprint: String,
    pub verdict: TriageVerdict,
    #[serde(default)]
    pub rationale: String,
}

/// Response for the same endpoint. `accepted: false` always means nothing
/// was written to `task_board_triage_decisions` -- only the escalation
/// row's own status changed.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardTriageEscalationVerdictResponse {
    pub accepted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejected_reason: Option<String>,
}
