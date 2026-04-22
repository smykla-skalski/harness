use crate::hooks::adapters::HookAgent;
use crate::observe::types::IssueCode;
use crate::session::service;
use crate::session::types::SessionRole;

use super::scan::scan_all_agents;
use super::test_support::{start_active_session, with_temp_project, write_agent_log_lines};

#[test]
fn observe_detects_cross_agent_file_conflicts_across_agents() {
    with_temp_project(|project| {
        let state = start_active_session(project, "sess-4", "observe test");

        temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
            service::join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join codex worker");
        });

        write_agent_log_lines(
            project,
            HookAgent::Claude,
            "leader-session",
            &[
                serde_json::json!({
                    "timestamp": "2026-03-28T12:00:00Z",
                    "message": {
                        "role": "assistant",
                        "content": [{
                            "type": "tool_use",
                            "id": "write-1",
                            "name": "Write",
                            "input": { "file_path": "src/shared.rs", "content": "leader edit" }
                        }]
                    }
                }),
                serde_json::json!({
                    "timestamp": "2026-03-28T12:00:01Z",
                    "message": {
                        "role": "assistant",
                        "content": [{
                            "type": "tool_result",
                            "tool_use_id": "write-1",
                            "content": "The file src/shared.rs has been updated successfully"
                        }]
                    }
                }),
            ],
        );
        write_agent_log_lines(
            project,
            HookAgent::Codex,
            "worker-session",
            &[
                serde_json::json!({
                    "timestamp": "2026-03-28T12:00:02Z",
                    "message": {
                        "role": "assistant",
                        "content": [{
                            "type": "tool_use",
                            "id": "write-2",
                            "name": "Write",
                            "input": { "file_path": "src/shared.rs", "content": "worker edit" }
                        }]
                    }
                }),
                serde_json::json!({
                    "timestamp": "2026-03-28T12:00:03Z",
                    "message": {
                        "role": "assistant",
                        "content": [{
                            "type": "tool_result",
                            "tool_use_id": "write-2",
                            "content": "The file src/shared.rs has been updated successfully"
                        }]
                    }
                }),
            ],
        );

        let observed = service::session_status("sess-4", project).expect("load session");
        let issues = scan_all_agents(&observed, "sess-4", project).expect("scan logs");

        assert!(
            issues
                .iter()
                .any(|issue| issue.code == IssueCode::CrossAgentFileConflict),
            "expected cross-agent conflict issue from shared editor state",
        );
    });
}
