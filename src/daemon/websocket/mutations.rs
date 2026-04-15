use std::future::Future;
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
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
