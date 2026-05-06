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

#[test]
fn dispatch_mutation_with_agent_accepts_session_agent_id_alias() {
    let state = test_ws_state();
    let request = WsRequest {
        id: "req-agent-alias".into(),
        method: "agent.change_role".into(),
        params: json!({
            "session_id": "sess-1",
            "session_agent_id": "worker-1",
            "actor": "spoofed-leader",
        }),
        trace_context: None,
    };

    let response =
        dispatch_mutation_with_agent(&request, &state, |session_id, agent_id, params, _db| {
            assert_eq!(session_id, "sess-1");
            assert_eq!(agent_id, "worker-1");
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

#[test]
fn dispatch_mutation_with_agent_rejects_managed_agent_id_alias() {
    let state = test_ws_state();
    let request = WsRequest {
        id: "req-agent-wrong-id".into(),
        method: "agent.change_role".into(),
        params: json!({
            "session_id": "sess-1",
            "managed_agent_id": "tui-1",
            "actor": "spoofed-leader",
        }),
        trace_context: None,
    };

    let response =
        dispatch_mutation_with_agent(&request, &state, |_session_id, _agent_id, _params, _db| {
            unreachable!("managed agent ids must not satisfy session-agent mutations")
        });

    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("MISSING_PARAM")
    );
}
