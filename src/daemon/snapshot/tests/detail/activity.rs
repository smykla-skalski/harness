use tempfile::tempdir;

use crate::daemon::snapshot::{
    session_detail,
    tests::support::{
        sample_state, sample_state_for_runtime, sample_work_item, write_json, write_json_line,
    },
};
use crate::session::types::{AgentRegistration, AgentStatus, SessionRole, TaskSeverity};

#[test]
fn session_detail_applies_shared_agent_and_task_ordering() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-ordering");
            let session_id = "sess-ordering";
            let state_path = context_root
                .join("orchestration")
                .join("sessions")
                .join(session_id)
                .join("state.json");

            let mut state = sample_state(session_id);
            state.agents.insert(
                "leader-1".into(),
                AgentRegistration {
                    agent_id: "leader-1".into(),
                    name: "Leader".into(),
                    runtime: "claude".into(),
                    role: SessionRole::Leader,
                    capabilities: vec![],
                    joined_at: "2026-03-28T13:58:00Z".into(),
                    updated_at: "2026-03-28T14:06:00Z".into(),
                    status: AgentStatus::Active,
                    agent_session_id: Some("leader-session".into()),
                    last_activity_at: Some("2026-03-28T14:06:00Z".into()),
                    current_task_id: None,
                    runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
                    persona: None,
                },
            );
            state.agents.insert(
                "reviewer-1".into(),
                AgentRegistration {
                    agent_id: "reviewer-1".into(),
                    name: "Reviewer".into(),
                    runtime: "codex".into(),
                    role: SessionRole::Reviewer,
                    capabilities: vec![],
                    joined_at: "2026-03-28T14:01:00Z".into(),
                    updated_at: "2026-03-28T14:05:00Z".into(),
                    status: AgentStatus::Active,
                    agent_session_id: Some("reviewer-session".into()),
                    last_activity_at: Some("2026-03-28T14:05:00Z".into()),
                    current_task_id: None,
                    runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
                    persona: None,
                },
            );
            state.leader_id = Some("leader-1".into());

            state.tasks.insert(
                "task-a".into(),
                sample_work_item(
                    "task-a",
                    TaskSeverity::Critical,
                    "2026-03-28T13:00:00Z",
                    "2026-03-28T14:00:00Z",
                ),
            );
            state.tasks.insert(
                "task-b".into(),
                sample_work_item(
                    "task-b",
                    TaskSeverity::Critical,
                    "2026-03-28T13:10:00Z",
                    "2026-03-28T14:00:00Z",
                ),
            );
            state.tasks.insert(
                "task-c".into(),
                sample_work_item(
                    "task-c",
                    TaskSeverity::High,
                    "2026-03-28T13:20:00Z",
                    "2026-03-28T14:05:00Z",
                ),
            );

            write_json(&state_path, &state);

            let detail = session_detail(session_id).expect("detail");
            let agent_order: Vec<_> = detail
                .agents
                .into_iter()
                .map(|agent| agent.agent_id)
                .collect();
            assert_eq!(agent_order, vec!["leader-1", "reviewer-1", "codex-worker"]);

            let task_order: Vec<_> = detail.tasks.into_iter().map(|task| task.task_id).collect();
            assert_eq!(task_order, vec!["task-b", "task-a", "task-c"]);
        },
    );
}

#[test]
fn session_detail_agent_activity_falls_back_to_ledger_for_copilot() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = tmp.path().join("harness/projects/project-alpha");
            let session_id = "sess-copilot";
            let state_path = context_root
                .join("orchestration")
                .join("sessions")
                .join(session_id)
                .join("state.json");
            write_json(
                &state_path,
                &sample_state_for_runtime(session_id, "copilot", "copilot-session-1"),
            );

            let ledger_path = context_root.join("agents/ledger/events.jsonl");
            write_json_line(
                &ledger_path,
                &serde_json::json!({
                    "sequence": 1,
                    "recorded_at": "2026-03-28T14:04:45Z",
                    "agent": "copilot",
                    "session_id": "copilot-session-1",
                    "skill": "suite",
                    "event": "before_tool_use",
                    "hook": "tool-guard",
                    "decision": "allow",
                    "payload": serde_json::json!({
                        "timestamp": "2026-03-28T14:04:45Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "name": "Read",
                                "input": {"path": "README.md"},
                                "id": "call-read-1",
                            }]
                        }
                    }),
                }),
            );
            write_json_line(
                &ledger_path,
                &serde_json::json!({
                    "sequence": 2,
                    "recorded_at": "2026-03-28T14:04:46Z",
                    "agent": "copilot",
                    "session_id": "copilot-session-1",
                    "skill": "suite",
                    "event": "after_tool_use",
                    "hook": "tool-result",
                    "decision": "allow",
                    "payload": serde_json::json!({
                        "timestamp": "2026-03-28T14:04:46Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_result",
                                "tool_name": "Read",
                                "tool_use_id": "call-read-1",
                                "content": {"line_count": 12},
                                "is_error": false,
                            }]
                        }
                    }),
                }),
            );

            let detail = session_detail(session_id).expect("detail");
            assert_eq!(detail.agent_activity.len(), 1);
            assert_eq!(detail.agent_activity[0].agent_id, "copilot-worker");
            assert_eq!(detail.agent_activity[0].runtime, "copilot");
            assert_eq!(detail.agent_activity[0].tool_invocation_count, 1);
            assert_eq!(detail.agent_activity[0].tool_result_count, 1);
            assert_eq!(detail.agent_activity[0].tool_error_count, 0);
            assert_eq!(
                detail.agent_activity[0].latest_tool_name.as_deref(),
                Some("Read")
            );
        },
    );
}
