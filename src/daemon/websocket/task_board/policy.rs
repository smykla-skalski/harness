use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{WsRequest, WsResponse, ws_methods};

mod canvas;
mod io;
mod pipeline;
mod scenario;

use self::canvas::{
    dispatch_task_board_policy_canvas_create, dispatch_task_board_policy_canvas_delete,
    dispatch_task_board_policy_canvas_duplicate, dispatch_task_board_policy_canvas_rename,
    dispatch_task_board_policy_canvas_set_active,
    dispatch_task_board_policy_canvas_set_global_enforcement,
    dispatch_task_board_policy_canvas_workspace_get,
};
use self::io::{dispatch_task_board_policy_export, dispatch_task_board_policy_import};
use self::pipeline::{
    dispatch_task_board_policy_pipeline_audit, dispatch_task_board_policy_pipeline_get,
    dispatch_task_board_policy_pipeline_go_live_diff,
    dispatch_task_board_policy_pipeline_make_live, dispatch_task_board_policy_pipeline_promote,
    dispatch_task_board_policy_pipeline_replay, dispatch_task_board_policy_pipeline_save_draft,
    dispatch_task_board_policy_pipeline_simulate,
};
use self::scenario::{
    dispatch_task_board_policy_scenario_create, dispatch_task_board_policy_scenario_delete,
    dispatch_task_board_policy_scenario_reset, dispatch_task_board_policy_scenario_update,
};

pub(super) async fn dispatch_task_board_policy_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_policy_canvas_method(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_policy_pipeline_method(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_policy_scenario_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_io_method(request, state).await
}

async fn dispatch_policy_scenario_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_SCENARIO_CREATE => {
            Some(dispatch_task_board_policy_scenario_create(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_SCENARIO_UPDATE => {
            Some(dispatch_task_board_policy_scenario_update(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_SCENARIO_DELETE => {
            Some(dispatch_task_board_policy_scenario_delete(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_SCENARIO_RESET => {
            Some(dispatch_task_board_policy_scenario_reset(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_canvas_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_policy_canvas_read_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_canvas_mutate_method(request, state).await
}

async fn dispatch_policy_canvas_read_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_CANVAS_WORKSPACE_GET => {
            Some(dispatch_task_board_policy_canvas_workspace_get(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_CREATE => {
            Some(dispatch_task_board_policy_canvas_create(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DUPLICATE => {
            Some(dispatch_task_board_policy_canvas_duplicate(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_canvas_mutate_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_CANVAS_RENAME => {
            Some(dispatch_task_board_policy_canvas_rename(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_SET_ACTIVE => {
            Some(dispatch_task_board_policy_canvas_set_active(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_DELETE => {
            Some(dispatch_task_board_policy_canvas_delete(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT => {
            Some(dispatch_task_board_policy_canvas_set_global_enforcement(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_pipeline_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_policy_pipeline_read_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_pipeline_write_method(request, state).await
}

async fn dispatch_policy_pipeline_read_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GET => {
            Some(dispatch_task_board_policy_pipeline_get(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GO_LIVE_DIFF => {
            Some(dispatch_task_board_policy_pipeline_go_live_diff(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_REPLAY => {
            Some(dispatch_task_board_policy_pipeline_replay(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT => {
            Some(dispatch_task_board_policy_pipeline_audit(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_pipeline_write_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT => {
            Some(dispatch_task_board_policy_pipeline_save_draft(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE => {
            Some(dispatch_task_board_policy_pipeline_simulate(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE => {
            Some(dispatch_task_board_policy_pipeline_promote(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_PIPELINE_MAKE_LIVE => {
            Some(dispatch_task_board_policy_pipeline_make_live(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_io_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_POLICY_EXPORT => {
            Some(dispatch_task_board_policy_export(request, state).await)
        }
        ws_methods::TASK_BOARD_POLICY_IMPORT => {
            Some(dispatch_task_board_policy_import(request, state).await)
        }
        _ => None,
    }
}
