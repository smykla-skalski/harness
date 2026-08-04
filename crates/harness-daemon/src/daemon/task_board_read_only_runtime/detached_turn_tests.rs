//! End-to-end cover for the reported regression: a report turn fails with a
//! provider error, its agent detaches, and reconciliation must keep the cause.

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tempfile::tempdir;

use super::recovery_tests::{restarted_state, seed_session};
use super::{ProductionTaskBoardReadOnlyRuntime, TaskBoardReadOnlyRuntime};
use crate::agents::acp::catalog::{
    self, AcpAgentDescriptor, AcpSessionConfiguration, AcpSpawnConfiguration,
};
use crate::daemon::agent_acp::{AcpAgentManagerHandle, AcpAgentStartRequest};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus, AsyncDaemonDb};
use crate::daemon::db_open::AsyncDaemonDbConnect;

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";
const AUTHENTICATION_DETAIL: &str = "OpenRouter rejected its credential: HTTP 401 unauthorized";
/// Generous on purpose: it only bounds a genuine hang, and the happy path
/// returns as soon as the spawned agent reports its failure.
const TURN_FAILURE_DEADLINE: Duration = Duration::from_secs(30);

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn production_load_keeps_the_provider_failure_after_the_turn_detaches() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("harness.db");
    let db = Arc::new(
        AsyncDaemonDb::connect(&db_path)
            .await
            .expect("open async database"),
    );
    seed_session(db.as_ref(), SESSION_ID).await;
    let state = restarted_state(&db_path, db.clone());

    let script = directory.path().join("failing-agent.py");
    write_prompt_rejecting_acp_agent(&script);
    let acp_id = start_and_reject(&state.acp_agent_manager, &script, directory.path());
    wait_until_detached(&state.acp_agent_manager, &acp_id);

    let run = active_run(&acp_id, directory.path());
    db.save_agent_turn_run(&run)
        .await
        .expect("save active agent-turn run");
    let runtime = ProductionTaskBoardReadOnlyRuntime::new(&state, db.as_ref());

    let reconciled = runtime
        .load_agent_turn_report_run(&run.run_id)
        .await
        .expect("load detached agent-turn run")
        .expect("settled durable run");

    assert_eq!(reconciled.status, AgentTurnRunStatus::Failed);
    assert_eq!(reconciled.error.as_deref(), Some(AUTHENTICATION_DETAIL));
}

/// Start the fake agent with a prompt and wait until it reports the rejection.
///
/// The wait reads the session directly rather than `inspect`, because the agent
/// exits as it rejects and `inspect` may already be hiding it by then.
fn start_and_reject(manager: &AcpAgentManagerHandle, script: &Path, project_dir: &Path) -> String {
    let request = AcpAgentStartRequest {
        agent: "fake".to_string(),
        project_dir: Some(project_dir.display().to_string()),
        prompt: Some("Return the report-only review JSON.".to_string()),
        ..AcpAgentStartRequest::default()
    };
    let snapshot = manager
        .start_descriptor_with_pooling_and_openrouter_token(
            SESSION_ID,
            &request,
            &descriptor(script),
            true,
            None,
        )
        .expect("start the fake ACP agent");
    let deadline = Instant::now() + TURN_FAILURE_DEADLINE;
    loop {
        let reported = manager
            .detached_turn_state(SESSION_ID, &snapshot.acp_id)
            .expect("read the turn state")
            .is_some_and(|state| state.last_turn_failure.is_some());
        if reported {
            return snapshot.acp_id;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for the ACP turn to report its failure"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The agent exits on its own after rejecting the prompt, so wait for `inspect`
/// to stop reporting it. That is the exact window the regression opened in.
fn wait_until_detached(manager: &AcpAgentManagerHandle, acp_id: &str) {
    let deadline = Instant::now() + TURN_FAILURE_DEADLINE;
    loop {
        let inspect = manager.inspect(Some(SESSION_ID)).expect("inspect");
        if inspect.agents.iter().all(|agent| agent.acp_id != acp_id) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for the failed ACP turn to detach"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn descriptor(command: &Path) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "fake".to_string(),
        display_name: "Fake ACP".to_string(),
        capabilities: Vec::new(),
        launch_command: command.display().to_string(),
        launch_args: Vec::new(),
        env_passthrough: Vec::new(),
        spawn_configuration: AcpSpawnConfiguration::default(),
        model_catalog: None,
        install_hint: None,
        session_configuration: AcpSessionConfiguration::default(),
        doctor_probe: catalog::DoctorProbe {
            command: command.display().to_string(),
            args: Vec::new(),
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: false,
        bundled_with_harness: false,
    }
}

/// A run recorded at start: active, correlated to the provider turn, and
/// carrying no outcome of its own yet.
fn active_run(acp_id: &str, project_dir: &Path) -> AgentTurnRunSnapshot {
    AgentTurnRunSnapshot {
        run_id: "openrouter-workflow-detached-review-1".into(),
        session_id: Some(SESSION_ID.into()),
        task_id: None,
        board_item_id: Some("item-detached".into()),
        workflow_execution_id: Some("execution-detached".into()),
        project_dir: Some(project_dir.display().to_string()),
        requested_runtime: "openrouter".into(),
        actual_runtime: Some("openrouter".into()),
        runtime_turn_id: Some(acp_id.to_string()),
        requested_model: None,
        actual_model: None,
        status: AgentTurnRunStatus::Running,
        source_revision: Some("0123456789abcdef0123456789abcdef01234567".into()),
        report: None,
        stop_reason: None,
        error: None,
        created_at: "2026-08-02T09:44:00Z".into(),
        updated_at: "2026-08-02T09:44:00Z".into(),
    }
}

/// An agent that completes the handshake and then rejects the prompt the way a
/// provider adapter does: a JSON-RPC error carrying a structured failure.
#[cfg(unix)]
fn write_prompt_rejecting_acp_agent(path: &Path) {
    use std::os::unix::fs::PermissionsExt;

    let failure = serde_json::json!({
        "category": "authentication",
        "stage": "execution",
        "automatic_retry_safe": false,
        "detail": AUTHENTICATION_DETAIL,
    })
    .to_string();
    let body = format!(
        r#"#!/usr/bin/env python3
import json
import sys

failure = json.loads({failure:?})
next_session = 1
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        result = {{"protocolVersion": message.get("params", {{}}).get("protocolVersion", 1),
                  "agentCapabilities": {{}}}}
    elif method == "session/new":
        result = {{"sessionId": f"acp-session-{{next_session}}"}}
        next_session += 1
    elif method == "session/prompt":
        if "id" in message:
            print(json.dumps({{"jsonrpc": "2.0", "id": message["id"],
                              "error": {{"code": -32000,
                                        "message": "provider rejected the request",
                                        "data": failure}}}}),
                  flush=True)
        # A fatal credential rejection takes the adapter down with it, which is
        # exactly the detach this test needs to happen on its own.
        sys.exit(0)
    else:
        result = {{}}
    if "id" in message:
        print(json.dumps({{"jsonrpc": "2.0", "id": message["id"], "result": result}}), flush=True)
"#
    );
    std::fs::write(path, body).expect("write fake agent script");
    let mut permissions = std::fs::metadata(path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).expect("chmod fake agent script");
}
