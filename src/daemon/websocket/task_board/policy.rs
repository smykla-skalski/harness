use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{WsRequest, WsResponse, ws_methods};

mod canvas;
mod io;
mod pipeline;
mod scenario;

use self::canvas::{
    dispatch_policy_approval_grant_resolve, dispatch_policy_approval_grant_revoke,
    dispatch_policy_approval_grants_list, dispatch_policy_canvas_create,
    dispatch_policy_canvas_delete, dispatch_policy_canvas_duplicate, dispatch_policy_canvas_rename,
    dispatch_policy_canvas_set_active, dispatch_policy_canvas_set_global_enforcement,
    dispatch_policy_canvas_set_spawn_kill_switch,
    dispatch_policy_canvas_set_spawn_requires_live_policy, dispatch_policy_canvas_workspace_get,
};
use self::io::{dispatch_policy_export, dispatch_policy_import};
use self::pipeline::{
    dispatch_policy_pipeline_audit, dispatch_policy_pipeline_get,
    dispatch_policy_pipeline_go_live_diff, dispatch_policy_pipeline_make_live,
    dispatch_policy_pipeline_promote, dispatch_policy_pipeline_replay,
    dispatch_policy_pipeline_save_draft, dispatch_policy_pipeline_simulate,
};
use self::scenario::{
    dispatch_policy_scenario_create, dispatch_policy_scenario_delete,
    dispatch_policy_scenario_reset, dispatch_policy_scenario_update,
};

pub(super) async fn dispatch_policy_method(
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
        ws_methods::POLICY_SCENARIO_CREATE => {
            Some(dispatch_policy_scenario_create(request, state).await)
        }
        ws_methods::POLICY_SCENARIO_UPDATE => {
            Some(dispatch_policy_scenario_update(request, state).await)
        }
        ws_methods::POLICY_SCENARIO_DELETE => {
            Some(dispatch_policy_scenario_delete(request, state).await)
        }
        ws_methods::POLICY_SCENARIO_RESET => {
            Some(dispatch_policy_scenario_reset(request, state).await)
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
    if let Some(response) = dispatch_policy_canvas_mutate_method(request, state).await {
        return Some(response);
    }
    dispatch_policy_spawn_gate_method(request, state).await
}

async fn dispatch_policy_canvas_read_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::POLICY_CANVAS_WORKSPACE_GET => {
            Some(dispatch_policy_canvas_workspace_get(request, state).await)
        }
        ws_methods::POLICY_CANVAS_CREATE => {
            Some(dispatch_policy_canvas_create(request, state).await)
        }
        ws_methods::POLICY_CANVAS_DUPLICATE => {
            Some(dispatch_policy_canvas_duplicate(request, state).await)
        }
        ws_methods::POLICY_APPROVAL_GRANTS_LIST => {
            Some(dispatch_policy_approval_grants_list(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_canvas_mutate_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::POLICY_CANVAS_RENAME => {
            Some(dispatch_policy_canvas_rename(request, state).await)
        }
        ws_methods::POLICY_CANVAS_SET_ACTIVE => {
            Some(dispatch_policy_canvas_set_active(request, state).await)
        }
        ws_methods::POLICY_CANVAS_DELETE => {
            Some(dispatch_policy_canvas_delete(request, state).await)
        }
        ws_methods::POLICY_CANVAS_SET_GLOBAL_ENFORCEMENT => {
            Some(dispatch_policy_canvas_set_global_enforcement(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_spawn_gate_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::POLICY_CANVAS_SET_SPAWN_REQUIRES_LIVE_POLICY => {
            Some(dispatch_policy_canvas_set_spawn_requires_live_policy(request, state).await)
        }
        ws_methods::POLICY_CANVAS_SET_SPAWN_KILL_SWITCH => {
            Some(dispatch_policy_canvas_set_spawn_kill_switch(request, state).await)
        }
        ws_methods::POLICY_APPROVAL_GRANT_RESOLVE => {
            Some(dispatch_policy_approval_grant_resolve(request, state).await)
        }
        ws_methods::POLICY_APPROVAL_GRANT_REVOKE => {
            Some(dispatch_policy_approval_grant_revoke(request, state).await)
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
        ws_methods::POLICY_PIPELINE_GET => Some(dispatch_policy_pipeline_get(request, state).await),
        ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF => {
            Some(dispatch_policy_pipeline_go_live_diff(request, state).await)
        }
        ws_methods::POLICY_PIPELINE_REPLAY => {
            Some(dispatch_policy_pipeline_replay(request, state).await)
        }
        ws_methods::POLICY_PIPELINE_AUDIT => {
            Some(dispatch_policy_pipeline_audit(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_pipeline_write_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::POLICY_PIPELINE_SAVE_DRAFT => {
            Some(dispatch_policy_pipeline_save_draft(request, state).await)
        }
        ws_methods::POLICY_PIPELINE_SIMULATE => {
            Some(dispatch_policy_pipeline_simulate(request, state).await)
        }
        ws_methods::POLICY_PIPELINE_PROMOTE => {
            Some(dispatch_policy_pipeline_promote(request, state).await)
        }
        ws_methods::POLICY_PIPELINE_MAKE_LIVE => {
            Some(dispatch_policy_pipeline_make_live(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_policy_io_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::POLICY_CANVAS_EXPORT => Some(dispatch_policy_export(request, state).await),
        ws_methods::POLICY_CANVAS_IMPORT => Some(dispatch_policy_import(request, state).await),
        _ => None,
    }
}
