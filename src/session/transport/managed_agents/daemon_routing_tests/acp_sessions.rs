//! Daemon-routing coverage for `managed_agents/acp_sessions.rs`, plus the
//! `acp_id`/`agent_session_id` path-segment rejection tests.

use harness_workspace::command_context::{AppContext, Execute};

use super::super::acp_sessions::{AcpCloseSessionArgs, AcpDeleteSessionArgs, AcpSessionsArgs};
use super::support::{ok_response_json, run_against_fake_daemon};

#[test]
fn acp_sessions_list_routes_through_leaf_client_with_query() {
    let response = serde_json::json!({ "sessions": [] }).to_string();
    let captured = run_against_fake_daemon(response, || {
        let args = AcpSessionsArgs {
            acp_id: "acp-1".into(),
            cwd: Some("/work".into()),
            cursor: Some("page-2".into()),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert!(
        captured
            .path
            .starts_with("/v1/managed-agents/acp-1/sessions?"),
        "path: {}",
        captured.path
    );
    assert!(captured.path.contains("cwd=%2Fwork"), "{}", captured.path);
    assert!(captured.path.contains("cursor=page-2"), "{}", captured.path);
}

#[test]
fn acp_close_session_routes_through_leaf_client() {
    let captured = run_against_fake_daemon(ok_response_json(), || {
        let args = AcpCloseSessionArgs {
            acp_id: "acp-1".into(),
            agent_session_id: "agent-session-7".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/managed-agents/acp-1/sessions/agent-session-7/close"
    );
    assert_eq!(captured.body, "{}");
}

#[test]
fn acp_delete_session_routes_through_leaf_client() {
    let captured = run_against_fake_daemon(ok_response_json(), || {
        let args = AcpDeleteSessionArgs {
            acp_id: "acp-1".into(),
            agent_session_id: "agent-session-9".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "DELETE");
    assert_eq!(
        captured.path,
        "/v1/managed-agents/acp-1/sessions/agent-session-9"
    );
}

#[test]
fn acp_sessions_list_rejects_an_acp_id_that_would_escape_its_path_segment() {
    let args = AcpSessionsArgs {
        acp_id: "../orchestrator/stop".into(),
        cwd: None,
        cursor: None,
    };
    let error = args
        .execute(&AppContext)
        .expect_err("an acp id with a path separator must be rejected before any request");
    assert!(error.to_string().contains("../orchestrator/stop"));
}

#[test]
fn acp_close_session_rejects_an_agent_session_id_that_would_escape_its_path_segment() {
    let args = AcpCloseSessionArgs {
        acp_id: "acp-1".into(),
        agent_session_id: "foo/../bar".into(),
    };
    let error = args.execute(&AppContext).expect_err(
        "an agent-reported session id with a path separator must be rejected before any request",
    );
    assert!(error.to_string().contains("foo/../bar"));
}
