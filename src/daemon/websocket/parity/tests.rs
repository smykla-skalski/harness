use std::fs;
use std::time::Duration;

use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::tempdir;
use tokio::time::timeout;

use super::*;
use crate::daemon::protocol::WsRequest;
use crate::session::types::CURRENT_VERSION;

fn write_valid_session(root: &std::path::Path, sid: &str, origin: &str) {
    fs::create_dir_all(root.join("workspace")).expect("create workspace");
    fs::create_dir_all(root.join("memory")).expect("create memory");
    let state = format!(
        "{{\"schema_version\":{CURRENT_VERSION},\"session_id\":\"{sid}\",\"project_name\":\"demo\",\
          \"origin_path\":\"{origin}\",\"worktree_path\":\"\",\"shared_path\":\"\",\
          \"branch_ref\":\"harness/{sid}\",\"title\":\"t\",\"context\":\"c\",\
          \"status\":\"active\",\"created_at\":\"2026-04-20T00:00:00Z\",\
          \"updated_at\":\"2026-04-20T00:00:00Z\"}}"
    );
    fs::write(root.join("state.json"), state).expect("write state");
    fs::write(root.join(".origin"), origin).expect("write origin");
}

#[tokio::test]
async fn sync_session_title_reports_poisoned_db_lock_as_ws_error() {
    let temp = tempdir().expect("tempdir");
    let db_path = temp.path().join("harness.db");
    let state = super::super::tests::test_websocket_state_with_sync_db_only(&db_path);
    let db = state.db.get().expect("db slot").clone();

    let poison = std::thread::spawn(move || {
        let _guard = db.lock().expect("lock db");
        panic!("poison db");
    })
    .join();
    assert!(poison.is_err(), "db lock should be poisoned");

    let response = dispatch_session_title(
        &WsRequest {
            id: "req-poisoned-db".into(),
            method: "session.title".into(),
            params: json!({
                "session_id": "sess-test-1",
                "title": "renamed session",
            }),
            trace_context: None,
        },
        &state,
    )
    .await;

    let error = response.error.expect("structured websocket error");
    assert_eq!(error.code, "WORKFLOW_IO");
    assert!(
        error.message.contains("daemon database lock poisoned"),
        "unexpected error message: {}",
        error.message
    );
}

#[tokio::test]
async fn parity_concurrent_mutation_serializes_acp_start_by_session_and_agent() {
    let state = super::super::test_support::test_ws_state();
    let mutation_guard = state
        .managed_agent_mutation_locks
        .lock("sess-test-1", "acp-worker")
        .await;

    let request = WsRequest {
        id: "req-start-acp".into(),
        method: "managed_agent.start_acp".into(),
        params: json!({
            "session_id": "sess-test-1",
            "agent": "acp-worker",
        }),
        trace_context: None,
    };
    let future = dispatch_managed_agent_start_acp(&request, &state);
    tokio::pin!(future);

    assert!(
        timeout(Duration::from_millis(50), future.as_mut())
            .await
            .is_err(),
        "ACP start should wait for the existing session+agent mutation guard",
    );

    drop(mutation_guard);

    let response = timeout(Duration::from_secs(1), future)
        .await
        .expect("ACP start should resume after the guard is released");
    assert!(
        response.result.is_some() || response.error.is_some(),
        "ACP start should complete with a websocket response once unblocked",
    );
}

#[tokio::test]
async fn dispatch_managed_agent_stop_acp_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let state = super::super::test_support::test_ws_state();
        let request = WsRequest {
            id: "req-stop-acp-disabled".into(),
            method: "managed_agent.stop_acp".into(),
            params: json!({
                "agent_id": "acp-worker",
            }),
            trace_context: None,
        };

        let response = dispatch_managed_agent_stop_acp(&request, &state).await;

        let error = response.error.expect("ACP disabled error");
        assert_eq!(error.code, "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn dispatch_managed_agent_resolve_acp_permission_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let state = super::super::test_support::test_ws_state();
        let request = WsRequest {
            id: "req-resolve-acp-disabled".into(),
            method: "managed_agent.resolve_acp_permission".into(),
            params: json!({
                "agent_id": "acp-worker",
                "batch_id": "batch-1",
                "decision": "approve_all",
            }),
            trace_context: None,
        };

        let response = dispatch_managed_agent_resolve_acp_permission(&request, &state).await;

        let error = response.error.expect("ACP disabled error");
        assert_eq!(error.code, "ACP_DISABLED");
    })
    .await;
}

#[test]
fn session_adopt_reports_poisoned_db_lock_as_ws_error() {
    let temp = tempdir().expect("tempdir");

    with_isolated_harness_env(temp.path(), || {
        let data_root = temp.path().join("harness");
        let sessions_dir = data_root.join("sessions");
        let session_dir = sessions_dir.join("demo/abc12345");
        let origin = temp.path().join("src/demo");
        fs::create_dir_all(&session_dir).expect("create session dir");
        fs::create_dir_all(&origin).expect("create origin dir");
        write_valid_session(
            &session_dir,
            "abc12345",
            origin.to_str().expect("origin path utf8"),
        );

        let db_path = temp.path().join("adopt.db");
        let state = super::super::tests::test_websocket_state_with_sync_db_only(&db_path);
        let db = state.db.get().expect("db slot").clone();
        let poison = std::thread::spawn(move || {
            let _guard = db.lock().expect("lock db");
            panic!("poison db");
        })
        .join();
        assert!(poison.is_err(), "db lock should be poisoned");

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let response = runtime.block_on(dispatch_session_adopt(
            &WsRequest {
                id: "req-adopt-poisoned-db".into(),
                method: "session.adopt".into(),
                params: json!({
                    "session_root": session_dir.to_string_lossy().into_owned(),
                }),
                trace_context: None,
            },
            &state,
        ));

        let error = response.error.expect("structured websocket error");
        assert_eq!(error.code, "WORKFLOW_IO");
        assert!(
            error.message.contains("daemon database lock poisoned"),
            "unexpected error message: {}",
            error.message
        );
    });
}
