use serde_json::Value;

use crate::daemon::protocol::{WsRequest, WsResponse, bind_control_plane_actor_value};

use super::super::frames::error_response;
use super::super::params::{extract_session_id, extract_string_param};

#[derive(Debug, Clone, Copy)]
pub(super) enum ActorBinding {
    ControlPlane,
    Preserve,
}

impl ActorBinding {
    fn apply(self, params: &mut Value) {
        if matches!(self, Self::ControlPlane) {
            bind_control_plane_actor_value(params);
        }
    }
}

pub(super) fn task_mutation_request_parts(
    request: &WsRequest,
    actor_binding: ActorBinding,
) -> Result<(String, String, Value), Box<WsResponse>> {
    let Some(session_id) = extract_session_id(&request.params) else {
        return Err(Box::new(error_response(
            &request.id,
            "MISSING_PARAM",
            "missing session_id",
        )));
    };
    let Some(task_id) = extract_string_param(&request.params, "task_id") else {
        return Err(Box::new(error_response(
            &request.id,
            "MISSING_PARAM",
            "missing task_id",
        )));
    };
    let mut params = request.params.clone();
    actor_binding.apply(&mut params);
    Ok((session_id, task_id, params))
}
