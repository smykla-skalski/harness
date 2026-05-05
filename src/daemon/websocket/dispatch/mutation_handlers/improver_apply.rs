use super::{DaemonHttpState, WsRequest, WsResponse, service};
use crate::daemon::protocol::ImproverApplyRequest;
use crate::daemon::protocol::bind_control_plane_actor_value;
use crate::daemon::websocket::frames::{error_response, ok_response};

pub(crate) async fn dispatch_improver_apply(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let session_id = params
        .get("session_id")
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string();
    let body: ImproverApplyRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAM",
                &format!("invalid improver apply request: {error}"),
            );
        }
    };
    let result = if let Some(async_db) = state.async_db.get().cloned() {
        service::improver_apply_async(&session_id, &body, async_db.as_ref()).await
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        service::improver_apply(&session_id, &body, db_guard.as_deref())
    };
    match result {
        Ok(outcome) => match serde_json::to_value(outcome) {
            Ok(value) => ok_response(&request.id, value),
            Err(error) => error_response(
                &request.id,
                "SERIALIZE_ERROR",
                &format!("failed to serialize improver outcome: {error}"),
            ),
        },
        Err(error) => error_response(&request.id, "IMPROVER_APPLY_FAILED", &error.to_string()),
    }
}
