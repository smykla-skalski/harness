use crate::daemon::http::{DaemonHttpState, require_async_db, task_board_route_executor};
use crate::daemon::protocol::{
    PolicyCanvasExportRequest, PolicyCanvasImportRequest, WsRequest, WsResponse,
};
use crate::daemon::websocket::mutations::dispatch_query_result;

use super::super::{invalid_params, parse_params, parse_params_or_default};

pub(super) async fn dispatch_policy_export(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params_or_default::<PolicyCanvasExportRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy export") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::export_policy_canvas(db, &body).await,
    )
}

pub(super) async fn dispatch_policy_import(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_params::<PolicyCanvasImportRequest>(request) else {
        return invalid_params(request);
    };
    let db = match require_async_db(state, "policy import") {
        Ok(db) => db,
        Err(error) => return dispatch_query_result(&request.id, Err::<(), _>(error)),
    };
    let result = task_board_route_executor::import_policy_canvas(db, &body).await;
    super::super::record_task_board_audit_result(
        state,
        "policy_canvas.import",
        "Import policy canvas",
        body.title.as_deref(),
        serde_json::json!({
            "title": &body.title,
        }),
        &result,
    )
    .await;
    dispatch_query_result(&request.id, result)
}
