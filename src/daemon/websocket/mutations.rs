use std::future::Future;
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ensure_shared_db};
use crate::daemon::http::{DaemonHttpState, error_status_and_body};
use crate::daemon::protocol::{
    SessionDetail, SessionMutationResponse, SessionStartRequest, SetLogLevelRequest,
    WsErrorPayload, WsRequest, WsResponse, bind_control_plane_actor_value,
};
use crate::daemon::service;
use crate::errors::CliError;

use super::frames::{error_response, error_response_with_payload, ok_response};
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
        Err(error) => {
            error_response_with_payload(request_id, ws_error_payload_from_cli_error(&error))
        }
    }
}

pub(crate) fn ws_error_payload_from_cli_error(error: &CliError) -> WsErrorPayload {
    let (status, body) = error_status_and_body(error);
    WsErrorPayload {
        code: error.code().to_string(),
        message: error.message(),
        details: error
            .details()
            .map_or_else(Vec::new, |detail| vec![detail.to_string()]),
        status_code: Some(status.as_u16()),
        data: Some(body),
    }
}

pub(crate) fn cli_error_response(request_id: &str, error: &CliError) -> WsResponse {
    error_response_with_payload(request_id, ws_error_payload_from_cli_error(error))
}

pub(crate) fn dispatch_set_log_level(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let body: SetLogLevelRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("invalid set_log_level params: {error}"),
            );
        }
    };
    dispatch_query(&request.id, || service::set_log_level(&body, &state.sender))
}

pub(crate) async fn dispatch_session_start(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let body: SessionStartRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };

    let result = if let Some(async_db) = state.async_db.get() {
        let result = service::start_session_direct_async(&body, async_db.as_ref())
            .await
            .map(|session_state| SessionMutationResponse {
                state: session_state,
            });
        if result.is_ok() {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        }
        result
    } else {
        ensure_shared_db(&state.db).and_then(|db| {
            let db_guard = db.lock().expect("db lock");
            let response =
                service::start_session_direct(&body, Some(&db_guard)).map(|session_state| {
                    SessionMutationResponse {
                        state: session_state,
                    }
                });
            if response.is_ok() {
                service::broadcast_sessions_updated(&state.sender, Some(&db_guard));
            }
            response
        })
    };

    dispatch_query_result(&request.id, result)
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
        Err(error) => error_response_with_payload(&request.id, error.into_ws_error_payload()),
    }
}

pub(crate) async fn dispatch_mutation_prefer_async<SyncHandler, AsyncHandler, AsyncResult>(
    request: &WsRequest,
    state: &DaemonHttpState,
    sync_handler: SyncHandler,
    async_handler: AsyncHandler,
) -> WsResponse
where
    SyncHandler: FnOnce(String, Value, Option<&DaemonDb>) -> Result<SessionDetail, MutationError>,
    AsyncHandler: FnOnce(String, Value, Arc<AsyncDaemonDb>) -> AsyncResult,
    AsyncResult: Future<Output = Result<SessionDetail, MutationError>>,
{
    let Some(async_db) = state.async_db.get().cloned() else {
        return dispatch_mutation(request, state, sync_handler);
    };
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match async_handler(session_id.clone(), params, async_db.clone()).await {
        Ok(detail) => {
            service::broadcast_session_snapshot_async(
                &state.sender,
                &session_id,
                Some(async_db.as_ref()),
            )
            .await;
            dispatch_query_result(&request.id, Ok(detail))
        }
        Err(error) => error_response_with_payload(&request.id, error.into_ws_error_payload()),
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
        Err(error) => error_response_with_payload(&request.id, error.into_ws_error_payload()),
    }
}

pub(crate) async fn dispatch_mutation_with_task_prefer_async<
    SyncHandler,
    AsyncHandler,
    AsyncResult,
>(
    request: &WsRequest,
    state: &DaemonHttpState,
    sync_handler: SyncHandler,
    async_handler: AsyncHandler,
) -> WsResponse
where
    SyncHandler:
        FnOnce(String, String, Value, Option<&DaemonDb>) -> Result<SessionDetail, MutationError>,
    AsyncHandler: FnOnce(String, String, Value, Arc<AsyncDaemonDb>) -> AsyncResult,
    AsyncResult: Future<Output = Result<SessionDetail, MutationError>>,
{
    let Some(async_db) = state.async_db.get().cloned() else {
        return dispatch_mutation_with_task(request, state, sync_handler);
    };
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(task_id) = extract_string_param(&request.params, "task_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing task_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match async_handler(session_id.clone(), task_id, params, async_db.clone()).await {
        Ok(detail) => {
            service::broadcast_session_snapshot_async(
                &state.sender,
                &session_id,
                Some(async_db.as_ref()),
            )
            .await;
            dispatch_query_result(&request.id, Ok(detail))
        }
        Err(error) => error_response_with_payload(&request.id, error.into_ws_error_payload()),
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

pub(crate) async fn dispatch_mutation_with_agent_prefer_async<
    SyncHandler,
    AsyncHandler,
    AsyncResult,
>(
    request: &WsRequest,
    state: &DaemonHttpState,
    sync_handler: SyncHandler,
    async_handler: AsyncHandler,
) -> WsResponse
where
    SyncHandler:
        FnOnce(String, String, Value, Option<&DaemonDb>) -> Result<SessionDetail, MutationError>,
    AsyncHandler: FnOnce(String, String, Value, Arc<AsyncDaemonDb>) -> AsyncResult,
    AsyncResult: Future<Output = Result<SessionDetail, MutationError>>,
{
    let Some(async_db) = state.async_db.get().cloned() else {
        return dispatch_mutation_with_agent(request, state, sync_handler);
    };
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);

    match async_handler(session_id.clone(), agent_id, params, async_db.clone()).await {
        Ok(detail) => {
            service::broadcast_session_snapshot_async(
                &state.sender,
                &session_id,
                Some(async_db.as_ref()),
            )
            .await;
            dispatch_query_result(&request.id, Ok(detail))
        }
        Err(error) => error_response(&request.id, &error.code, &error.message),
    }
}

pub(crate) struct MutationError {
    code: String,
    message: String,
    status_code: Option<u16>,
    data: Option<Value>,
}

impl From<CliError> for MutationError {
    fn from(error: CliError) -> Self {
        let payload = ws_error_payload_from_cli_error(&error);
        Self {
            code: payload.code,
            message: payload.message,
            status_code: payload.status_code,
            data: payload.data,
        }
    }
}

impl From<serde_json::Error> for MutationError {
    fn from(error: serde_json::Error) -> Self {
        Self {
            code: "INVALID_PARAMS".into(),
            message: format!("failed to parse request params: {error}"),
            status_code: None,
            data: None,
        }
    }
}

impl MutationError {
    fn into_ws_error_payload(self) -> WsErrorPayload {
        WsErrorPayload {
            code: self.code,
            message: self.message,
            details: vec![],
            status_code: self.status_code,
            data: self.data,
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::super::test_support::{test_http_state_with_async_db_timeline, test_ws_state};
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
            trace_context: None,
        };

        let response = dispatch_mutation(&request, &state, |session_id, params, _db| {
            assert_eq!(session_id, "sess-1");
            assert_eq!(params["actor"], CONTROL_PLANE_ACTOR_ID);
            Err(MutationError {
                code: "EXPECTED".into(),
                message: "stop here".into(),
                status_code: None,
                data: None,
            })
        });

        assert_eq!(
            response.error.as_ref().map(|error| error.code.as_str()),
            Some("EXPECTED")
        );
    }

    #[tokio::test]
    async fn dispatch_mutation_prefer_async_rebinds_client_actor() {
        let state = test_http_state_with_async_db_timeline().await;
        let request = WsRequest {
            id: "req-async-1".into(),
            method: "session.end".into(),
            params: json!({
                "session_id": "sess-test-1",
                "actor": "spoofed-leader",
            }),
            trace_context: None,
        };

        let response = dispatch_mutation_prefer_async(
            &request,
            &state,
            |_session_id, _params, _db| {
                unreachable!("sync handler should not be used without async db")
            },
            |session_id, params, _async_db| async move {
                assert_eq!(session_id, "sess-test-1");
                assert_eq!(params["actor"], CONTROL_PLANE_ACTOR_ID);
                Err(MutationError {
                    code: "EXPECTED".into(),
                    message: "stop here".into(),
                    status_code: None,
                    data: None,
                })
            },
        )
        .await;

        assert_eq!(
            response.error.as_ref().map(|error| error.code.as_str()),
            Some("EXPECTED")
        );
    }
}
