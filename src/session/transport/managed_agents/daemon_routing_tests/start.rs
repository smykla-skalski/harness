//! Daemon-routing coverage for `managed_agents/start.rs`'s terminal/Codex/ACP
//! start commands plus ACP inspect and logout.

use harness_protocol::agent::HookAgent;
use harness_protocol::managed_agents::codex::CodexRunMode;
use harness_workspace::command_context::{AppContext, Execute};

use crate::session::types::SessionRole;

use super::super::start::{
    AcpAgentStartArgs, AcpInspectArgs, AcpLogoutArgs, CodexAgentStartArgs, TerminalAgentStartArgs,
};
use super::support::{
    acp_snapshot_json, codex_snapshot_json, ok_response_json, run_against_fake_daemon,
    terminal_snapshot_json,
};

#[test]
fn start_terminal_agent_routes_through_leaf_client() {
    let response = terminal_snapshot_json("tui-2", "00000000-0000-4000-8000-00000000b006");
    let captured = run_against_fake_daemon(response, || {
        let args = TerminalAgentStartArgs {
            session_id: "00000000-0000-4000-8000-00000000b006".into(),
            runtime: HookAgent::Claude,
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            prompt: None,
            project_dir: None,
            argv: Vec::new(),
            rows: 30,
            cols: 120,
            persona: None,
            model: None,
            effort: None,
            allow_custom_model: false,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b006/managed-agents/terminal"
    );
    assert!(captured.body.contains("\"runtime\":\"claude\""));
}

#[test]
fn start_codex_agent_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-2", "00000000-0000-4000-8000-00000000b007");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentStartArgs {
            session_id: "00000000-0000-4000-8000-00000000b007".into(),
            prompt: "investigate the failure".into(),
            mode: CodexRunMode::Report,
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            persona: None,
            resume_thread_id: None,
            model: None,
            effort: None,
            allow_custom_model: false,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b007/managed-agents/codex"
    );
    assert!(
        captured
            .body
            .contains("\"prompt\":\"investigate the failure\"")
    );
}

#[test]
fn start_acp_agent_routes_through_leaf_client() {
    let response = acp_snapshot_json("acp-2", "00000000-0000-4000-8000-00000000b008");
    let captured = run_against_fake_daemon(response, || {
        let args = AcpAgentStartArgs {
            session_id: "00000000-0000-4000-8000-00000000b008".into(),
            agent: "copilot".into(),
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            prompt: None,
            project_dir: None,
            persona: None,
            model: None,
            effort: None,
            allow_custom_model: false,
            record_permissions: false,
            additional_directories: Vec::new(),
            resume_session_id: None,
            no_resume: false,
            endpoint: None,
            header_env: Vec::new(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b008/managed-agents/acp"
    );
    assert!(captured.body.contains("\"descriptor_id\":\"copilot\""));
}

#[test]
fn acp_inspect_routes_through_leaf_client_with_session_filter() {
    let response = serde_json::json!({
        "agents": [],
        "daemon_perceived_now": null,
        "available": true,
        "issue_message": null,
    })
    .to_string();
    let captured = run_against_fake_daemon(response, || {
        let args = AcpInspectArgs {
            session_id: Some("00000000-0000-4000-8000-00000000b009".into()),
            json: true,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert!(
        captured.path.starts_with("/v1/managed-agents/acp/inspect?"),
        "path: {}",
        captured.path
    );
    assert!(
        captured
            .path
            .contains("session_id=00000000-0000-4000-8000-00000000b009"),
        "{}",
        captured.path
    );
}

#[test]
fn acp_logout_routes_through_leaf_client() {
    let captured = run_against_fake_daemon(ok_response_json(), || {
        let args = AcpLogoutArgs {
            acp_id: "acp-3".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/managed-agents/acp-3/logout");
    assert_eq!(captured.body, "{}");
}

#[test]
fn start_terminal_agent_rejects_a_session_id_that_would_escape_its_path_segment() {
    let args = TerminalAgentStartArgs {
        session_id: "../orchestrator/stop".into(),
        runtime: HookAgent::Claude,
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        prompt: None,
        project_dir: None,
        argv: Vec::new(),
        rows: 30,
        cols: 120,
        persona: None,
        model: None,
        effort: None,
        allow_custom_model: false,
    };
    let error = args
        .execute(&AppContext)
        .expect_err("a session id with a path separator must be rejected before any request");
    assert!(error.to_string().contains("../orchestrator/stop"));
}
