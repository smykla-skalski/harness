use serde::Deserialize;

use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::{
    TaskBoardActivateTriageRulesRequest, TaskBoardPreviewTriageRulesRequest,
    TaskBoardSaveTriageRulesDraftRequest, WsRequest, WsResponse, ws_methods,
};

use super::super::mutations::dispatch_query_result;
use super::{invalid_params, parse_control_plane_params, parse_params_or_default};

/// Dispatch a triage-rules method, or `None` when `request.method` names
/// something else. Split out of the parent task-board match arm so that
/// match stays under the crate's clippy function-length threshold.
pub(super) async fn dispatch_method(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_GET => {
            Some(dispatch_triage_rules_draft_get(request, state).await)
        }
        ws_methods::TASK_BOARD_TRIAGE_RULES_DRAFT_SAVE => {
            Some(dispatch_triage_rules_draft_save(request, state).await)
        }
        ws_methods::TASK_BOARD_TRIAGE_RULES_PREVIEW => {
            Some(dispatch_triage_rules_preview(request, state).await)
        }
        ws_methods::TASK_BOARD_TRIAGE_RULES_ACTIVATE => {
            Some(dispatch_triage_rules_activate(request, state).await)
        }
        ws_methods::TASK_BOARD_TRIAGE_RULES_REVISIONS => {
            Some(dispatch_triage_rules_revisions(request, state).await)
        }
        ws_methods::TASK_BOARD_TRIAGE_RULES_AUDIT => {
            Some(dispatch_triage_rules_audit(request, state).await)
        }
        _ => None,
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub(super) struct TriageRulesLimitParams {
    pub(super) limit: Option<u32>,
}

pub(super) async fn dispatch_triage_rules_draft_get(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_query_result(
        &request.id,
        task_board_route_executor::get_triage_rules_draft(state).await,
    )
}

pub(super) async fn dispatch_triage_rules_draft_save(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardSaveTriageRulesDraftRequest>(request)
    else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::save_triage_rules_draft(state, &body).await,
    )
}

pub(super) async fn dispatch_triage_rules_preview(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = serde_json::from_value::<TaskBoardPreviewTriageRulesRequest>(request.params.clone())
    else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::preview_triage_rules(state, &body).await,
    )
}

pub(super) async fn dispatch_triage_rules_activate(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(body) = parse_control_plane_params::<TaskBoardActivateTriageRulesRequest>(request)
    else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::activate_triage_rules(state, &body).await,
    )
}

pub(super) async fn dispatch_triage_rules_revisions(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(params) = parse_params_or_default::<TriageRulesLimitParams>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::get_triage_rules_revisions(state, params.limit).await,
    )
}

pub(super) async fn dispatch_triage_rules_audit(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Ok(params) = parse_params_or_default::<TriageRulesLimitParams>(request) else {
        return invalid_params(request);
    };
    dispatch_query_result(
        &request.id,
        task_board_route_executor::get_triage_rules_audit(state, params.limit).await,
    )
}
