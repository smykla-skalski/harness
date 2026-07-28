//! Daemon-routing coverage for `managed_agents.rs`'s list/show commands, plus
//! the `session_id`/`agent_id` path-segment rejection tests representative of
//! every other command in this suite that interpolates one of those two id
//! kinds into a URL.

use harness_workspace::command_context::{AppContext, Execute};

use super::super::{ManagedAgentListArgs, ManagedAgentShowArgs};
use super::support::{run_against_fake_daemon, terminal_snapshot_json};

#[test]
fn list_managed_agents_routes_through_leaf_client() {
    let response = serde_json::json!({ "agents": [] }).to_string();
    let captured = run_against_fake_daemon(response, || {
        let args = ManagedAgentListArgs {
            session_id: "00000000-0000-4000-8000-00000000b001".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b001/managed-agents"
    );
}

#[test]
fn get_managed_agent_routes_through_leaf_client() {
    let response = terminal_snapshot_json("tui-1", "00000000-0000-4000-8000-00000000b002");
    let captured = run_against_fake_daemon(response, || {
        let args = ManagedAgentShowArgs {
            agent_id: "tui-1".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert_eq!(captured.path, "/v1/managed-agents/tui-1");
}

#[test]
fn list_managed_agents_rejects_a_session_id_that_would_escape_its_path_segment() {
    let args = ManagedAgentListArgs {
        session_id: "../orchestrator/stop".into(),
    };
    let error = args
        .execute(&AppContext)
        .expect_err("a session id with a path separator must be rejected before any request");
    assert!(error.to_string().contains("../orchestrator/stop"));
}

#[test]
fn get_managed_agent_rejects_an_agent_id_that_would_escape_its_path_segment() {
    let args = ManagedAgentShowArgs {
        agent_id: "foo/../bar".into(),
    };
    let error = args
        .execute(&AppContext)
        .expect_err("an agent id with a path separator must be rejected before any request");
    assert!(error.to_string().contains("foo/../bar"));
}
