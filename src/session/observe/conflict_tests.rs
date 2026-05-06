use crate::hooks::adapters::HookAgent;
use crate::observe::types::IssueCode;
use crate::session::service;
use crate::session::types::SessionRole;

use super::scan::scan_all_agents;
use super::test_support::{start_active_session, with_temp_project, write_agent_log_lines};

#[test]
fn observe_detects_cross_agent_file_conflicts_across_agents() {
    with_temp_project(|project| {
        let state = start_active_session(
            project,
            "fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49",
            "observe test",
        );

        temp_env::with_vars(
            [(
                "CODEX_SESSION_ID",
                Some("008d974f-c6a9-53e5-a62e-d331367c449a"),
            )],
            || {
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
            },
        );

        write_agent_log_lines(
            project,
            HookAgent::Claude,
            "77d13b08-1651-541b-a3fc-26cab59e0aea",
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
            "008d974f-c6a9-53e5-a62e-d331367c449a",
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

        let observed = service::session_status("fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49", project)
            .expect("load session");
        let issues = scan_all_agents(&observed, "fbbde0b1-87ab-53c2-b7f0-9b9a3ecccb49", project)
            .expect("scan logs");

        assert!(
            issues
                .iter()
                .any(|issue| issue.code == IssueCode::CrossAgentFileConflict),
            "expected cross-agent conflict issue from shared editor state",
        );
    });
}
