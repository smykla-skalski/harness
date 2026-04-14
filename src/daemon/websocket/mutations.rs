use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    SessionDetail, WsRequest, WsResponse, bind_control_plane_actor_value,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::frames::{error_response, ok_response};
use super::params::{extract_session_id, extract_string_param};

pub(crate) fn dispatch_query<T: serde::Serialize>(
    request_id: &str,
    query: impl FnOnce() -> Result<T, CliError>,
) -> WsResponse {
    dispatch_query_result(request_id, query())
}

pub(crate) fn dispatch_query_result<T: serde::Serialize>(
    request_id: &str,
    result: Result<T, CliError>,
) -> WsResponse {
    match result {
        Ok(value) => match serde_json::to_value(value) {
            Ok(json) => ok_response(request_id, json),
            Err(error) => error_response(
                request_id,
                "SERIALIZE_ERROR",
                &format!("failed to serialize result: {error}"),
            ),
        },
        Err(error) => error_response(request_id, error.code(), &error.message()),
    }
}

pub(crate) fn dispatch_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
    handler: impl FnOnce(String, Value, Option<&DaemonDb>) -> Result<SessionDetail, MutationError>,
) -> WsResponse {
    let db_guard = state
        .db
        .get()
        .map(|db: &Arc<Mutex<DaemonDb>>| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match handler(session_id.clone(), params, db_ref) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
            match serde_json::to_value(detail) {
                Ok(json) => ok_response(&request.id, json),
                Err(error) => error_response(
                    &request.id,
                    "SERIALIZE_ERROR",
                    &format!("failed to serialize result: {error}"),
                ),
            }
        }
        Err(error) => error_response(&request.id, &error.code, &error.message),
    }
}

pub(crate) fn dispatch_mutation_with_task(
    request: &WsRequest,
    state: &DaemonHttpState,
    handler: impl FnOnce(
        String,
        String,
        Value,
        Option<&DaemonDb>,
    ) -> Result<SessionDetail, MutationError>,
) -> WsResponse {
    let db_guard = state
        .db
        .get()
        .map(|db: &Arc<Mutex<DaemonDb>>| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(task_id) = extract_string_param(&request.params, "task_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing task_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match handler(session_id.clone(), task_id, params, db_ref) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
            match serde_json::to_value(detail) {
                Ok(json) => ok_response(&request.id, json),
                Err(error) => error_response(
                    &request.id,
                    "SERIALIZE_ERROR",
                    &format!("failed to serialize result: {error}"),
                ),
            }
        }
        Err(error) => error_response(&request.id, &error.code, &error.message),
    }
}

pub(crate) fn dispatch_mutation_with_agent(
    request: &WsRequest,
    state: &DaemonHttpState,
    handler: impl FnOnce(
        String,
        String,
        Value,
        Option<&DaemonDb>,
    ) -> Result<SessionDetail, MutationError>,
) -> WsResponse {
    let db_guard = state
        .db
        .get()
        .map(|db: &Arc<Mutex<DaemonDb>>| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match handler(session_id.clone(), agent_id, params, db_ref) {
        Ok(detail) => {
            service::broadcast_session_snapshot(&state.sender, &session_id, db_ref);
            match serde_json::to_value(detail) {
                Ok(json) => ok_response(&request.id, json),
                Err(error) => error_response(
                    &request.id,
                    "SERIALIZE_ERROR",
                    &format!("failed to serialize result: {error}"),
                ),
            }
        }
        Err(error) => error_response(&request.id, &error.code, &error.message),
    }
}

pub(crate) struct MutationError {
    code: String,
    message: String,
}

impl From<CliError> for MutationError {
    fn from(error: CliError) -> Self {
        Self {
            code: error.code().to_string(),
            message: error.message(),
        }
    }
}

impl From<serde_json::Error> for MutationError {
    fn from(error: serde_json::Error) -> Self {
        Self {
            code: "INVALID_PARAMS".into(),
            message: format!("failed to parse request params: {error}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::super::test_support::test_ws_state;
    use super::*;
    use crate::daemon::protocol::WsRequest;
    use crate::session::types::CONTROL_PLANE_ACTOR_ID;

    #[test]
    fn dispatch_mutation_rebinds_client_actor() {
        let state = test_ws_state();
        let request = WsRequest {
            id: "req-1".into(),
            method: "session.end".into(),
            params: json!({
                "session_id": "sess-1",
                "actor": "spoofed-leader",
            }),
        };

        let response = dispatch_mutation(&request, &state, |session_id, params, _db| {
            assert_eq!(session_id, "sess-1");
            assert_eq!(params["actor"], CONTROL_PLANE_ACTOR_ID);
            Err(MutationError {
                code: "EXPECTED".into(),
                message: "stop here".into(),
            })
        });

        assert_eq!(
            response.error.as_ref().map(|error| error.code.as_str()),
            Some("EXPECTED")
        );
    }
}
