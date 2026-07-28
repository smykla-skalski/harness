//! Daemon-routing coverage for `managed_agents/codex.rs`, plus the
//! `approval_id` path-segment rejection test (the one id kind not already
//! covered by `managed_agents.rs`'s or `acp_sessions.rs`'s rejection tests).

use harness_protocol::managed_agents::codex::CodexApprovalDecision;
use harness_workspace::command_context::{AppContext, Execute};

use harness::session::transport::{
    CodexAgentApprovalArgs, CodexAgentInterruptArgs, CodexAgentSteerArgs,
};

use super::support::{codex_snapshot_json, run_against_fake_daemon};

#[test]
fn codex_steer_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-1", "00000000-0000-4000-8000-00000000b003");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentSteerArgs {
            agent_id: "run-1".into(),
            prompt: "keep going".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/managed-agents/run-1/steer");
    assert!(captured.body.contains("\"prompt\":\"keep going\""));
}

#[test]
fn codex_interrupt_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-1", "00000000-0000-4000-8000-00000000b004");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentInterruptArgs {
            agent_id: "run-1".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/managed-agents/run-1/interrupt");
    assert_eq!(captured.body, "{}");
}

#[test]
fn codex_approval_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-1", "00000000-0000-4000-8000-00000000b005");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentApprovalArgs {
            agent_id: "run-1".into(),
            approval_id: "approval-1".into(),
            decision: CodexApprovalDecision::Accept,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/managed-agents/run-1/approvals/approval-1"
    );
    assert!(captured.body.contains("\"decision\":\"accept\""));
}

#[test]
fn codex_approval_rejects_an_approval_id_that_would_escape_its_path_segment() {
    let args = CodexAgentApprovalArgs {
        agent_id: "run-1".into(),
        approval_id: "foo/../bar".into(),
        decision: CodexApprovalDecision::Accept,
    };
    let error = args
        .execute(&AppContext)
        .expect_err("an approval id with a path separator must be rejected before any request");
    assert!(error.to_string().contains("foo/../bar"));
}
