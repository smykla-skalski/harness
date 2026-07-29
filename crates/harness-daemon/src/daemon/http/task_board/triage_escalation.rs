use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::protocol::{
    TaskBoardTriageEscalationVerdictRequest, TaskBoardTriageEscalationVerdictResponse, http_paths,
};
use crate::task_board::TaskBoardTriageEscalationVerdictOutcome;

use super::super::openapi::DaemonErrorBody;
use super::super::response::{extract_request_id, timed_json};
use super::super::{DaemonHttpState, require_async_db};

/// No control-plane session auth: the caller is the daemon's own spawned
/// escalation worker, authenticated entirely by `verdict_token` matching the
/// row this escalation's executor claim minted. See the route catalog's
/// `Exempt` entry for this path for the full rationale.
#[utoipa::path(
    post,
    path = "/v1/task-board/triage/escalations/{escalation_id}/verdict",
    tag = "task-board",
    description = "Record the accept/reject verdict for a triage escalation. Authenticated by the request's verdict_token matching the escalation's executor claim rather than a control-plane session, since the caller is the daemon's own spawned escalation worker",
    params(("escalation_id" = String, Path, description = "Triage escalation identifier")),
    request_body = TaskBoardTriageEscalationVerdictRequest,
    responses(
        (status = 200, description = "Verdict outcome; `accepted: false` carries the rejection reason", body = TaskBoardTriageEscalationVerdictResponse),
        (status = 400, description = "Request error", body = DaemonErrorBody),
    ),
)]
pub(super) async fn post_task_board_triage_escalation_verdict(
    Path(escalation_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<TaskBoardTriageEscalationVerdictRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    let result = match require_async_db(&state, "task board triage escalation verdict") {
        Ok(db) => db
            .report_task_board_triage_escalation_verdict(
                &escalation_id,
                &request.verdict_token,
                &request.evidence_fingerprint,
                request.verdict,
                &request.rationale,
            )
            .await
            .map(response_for_outcome),
        Err(error) => Err(error),
    };
    timed_json(
        "POST",
        http_paths::TASK_BOARD_TRIAGE_ESCALATION_VERDICT,
        &request_id,
        start,
        result,
    )
}

fn response_for_outcome(
    outcome: TaskBoardTriageEscalationVerdictOutcome,
) -> TaskBoardTriageEscalationVerdictResponse {
    match outcome {
        TaskBoardTriageEscalationVerdictOutcome::Accepted => {
            TaskBoardTriageEscalationVerdictResponse {
                accepted: true,
                rejected_reason: None,
            }
        }
        TaskBoardTriageEscalationVerdictOutcome::Rejected(reason) => {
            TaskBoardTriageEscalationVerdictResponse {
                accepted: false,
                rejected_reason: Some(reason.wire_code().to_string()),
            }
        }
    }
}
