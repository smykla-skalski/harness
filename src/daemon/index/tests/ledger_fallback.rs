use super::*;

#[test]
fn load_conversation_events_falls_back_to_ledger_for_copilot() {
    let tmp = tempdir().expect("tempdir");
    let context_root = tmp.path().join("context");
    let ledger_path = context_root.join("agents/ledger/events.jsonl");
    let make_payload = |timestamp: &str, block: serde_json::Value| {
        serde_json::json!({
            "timestamp": timestamp,
            "message": {
                "role": "assistant",
                "content": [block],
            }
        })
    };
    let entries = [
        serde_json::json!({
            "sequence": 1,
            "recorded_at": "2026-03-29T10:00:00Z",
            "agent": "copilot",
            "session_id": "93595910-aac3-58cb-aadf-5101d4ce534b",
            "skill": "suite",
            "event": "before_tool_use",
            "hook": "tool-guard",
            "decision": "allow",
            "cwd": "/tmp/project",
            "payload": make_payload(
                "2026-03-29T10:00:00Z",
                serde_json::json!({
                    "type": "tool_use",
                    "name": "Read",
                    "input": {"path": "README.md"},
                    "id": "call-1",
                }),
            ),
        }),
        serde_json::json!({
            "sequence": 2,
            "recorded_at": "2026-03-29T10:00:02Z",
            "agent": "copilot",
            "session_id": "93595910-aac3-58cb-aadf-5101d4ce534b",
            "skill": "suite",
            "event": "after_tool_use",
            "hook": "tool-result",
            "decision": "allow",
            "cwd": "/tmp/project",
            "payload": make_payload(
                "2026-03-29T10:00:02Z",
                serde_json::json!({
                    "type": "tool_result",
                    "tool_name": "Read",
                    "tool_use_id": "call-1",
                    "content": {"line_count": 12},
                    "is_error": false,
                }),
            ),
        }),
    ];
    let contents = entries
        .iter()
        .map(|entry| serde_json::to_string(entry).expect("serialize"))
        .collect::<Vec<_>>()
        .join("\n");
    write_text(&ledger_path, &contents);

    let project = DiscoveredProject {
        project_id: "project-alpha".into(),
        name: "project-alpha".into(),
        project_dir: None,
        repository_root: None,
        checkout_id: "project-alpha".into(),
        checkout_name: "main".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };

    let events = load_conversation_events(
        &project,
        "copilot",
        "93595910-aac3-58cb-aadf-5101d4ce534b",
        "copilot-worker",
    )
    .expect("events");

    assert_eq!(events.len(), 2);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[0].agent, "copilot-worker");
    assert_eq!(events[0].session_id, "93595910-aac3-58cb-aadf-5101d4ce534b");
    assert!(matches!(
        events[0].kind,
        crate::agents::runtime::event::ConversationEventKind::ToolInvocation {
            ref tool_name,
            ..
        } if tool_name == "Read"
    ));
    assert!(matches!(
        events[1].kind,
        crate::agents::runtime::event::ConversationEventKind::ToolResult {
            ref tool_name,
            ..
        } if tool_name == "Read"
    ));
}
