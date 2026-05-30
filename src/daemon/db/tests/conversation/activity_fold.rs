use super::super::*;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::protocol::AgentToolActivitySummary;

const FOLD_SESSION_ID: &str = "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4";

fn ask_user_invocation(sequence: u64, timestamp: &str, invocation_id: &str) -> ConversationEvent {
    ConversationEvent {
        timestamp: Some(timestamp.to_string()),
        sequence,
        kind: ConversationEventKind::ToolInvocation {
            tool_name: "AskUserQuestion".to_string(),
            category: "interaction".to_string(),
            input: serde_json::json!({
                "questions": [{
                    "question": "Approve the write?",
                    "header": "Approval",
                    "options": [
                        { "label": "Allow", "description": "Proceed with the write" },
                        { "label": "Deny", "description": "Stop before writing" }
                    ],
                    "multi_select": false
                }]
            }),
            invocation_id: Some(invocation_id.to_string()),
        },
        agent: "claude-leader".to_string(),
        session_id: FOLD_SESSION_ID.to_string(),
    }
}

fn tool_invocation(
    sequence: u64,
    timestamp: &str,
    tool_name: &str,
    invocation_id: &str,
) -> ConversationEvent {
    ConversationEvent {
        timestamp: Some(timestamp.to_string()),
        sequence,
        kind: ConversationEventKind::ToolInvocation {
            tool_name: tool_name.to_string(),
            category: "fs".to_string(),
            input: serde_json::json!({ "path": "README.md" }),
            invocation_id: Some(invocation_id.to_string()),
        },
        agent: "claude-leader".to_string(),
        session_id: FOLD_SESSION_ID.to_string(),
    }
}

fn tool_result(
    sequence: u64,
    timestamp: &str,
    tool_name: &str,
    invocation_id: &str,
) -> ConversationEvent {
    ConversationEvent {
        timestamp: Some(timestamp.to_string()),
        sequence,
        kind: ConversationEventKind::ToolResult {
            tool_name: tool_name.to_string(),
            invocation_id: Some(invocation_id.to_string()),
            output: serde_json::json!({ "answer": "Allow" }),
            is_error: false,
            duration_ms: None,
        },
        agent: "claude-leader".to_string(),
        session_id: FOLD_SESSION_ID.to_string(),
    }
}

fn leader_activity(db: &DaemonDb) -> AgentToolActivitySummary {
    db.load_agent_activity(FOLD_SESSION_ID)
        .expect("load agent activity")
        .into_iter()
        .find(|activity| activity.agent_id == "claude-leader")
        .expect("claude-leader activity present")
}

fn activity_json(db: &DaemonDb) -> serde_json::Value {
    serde_json::to_value(
        db.load_agent_activity(FOLD_SESSION_ID)
            .expect("load activity"),
    )
    .expect("serialize activity")
}

#[test]
fn incremental_fold_matches_full_rebuild_with_pending_prompt() {
    let events = [
        ask_user_invocation(1, "2026-04-03T12:00:01Z", "ask-1"),
        tool_invocation(2, "2026-04-03T12:00:02Z", "Read", "call-2"),
        tool_invocation(3, "2026-04-03T12:00:03Z", "Edit", "call-3"),
    ];

    // Folded path: three separate appends. After the first append seeds the
    // cache, the second and third appends fold incrementally instead of
    // reloading the whole transcript.
    let folded_db = DaemonDb::open_in_memory().expect("open folded db");
    super::seed_conversation_session(&folded_db);
    for event in &events {
        folded_db
            .append_conversation_events(
                FOLD_SESSION_ID,
                "claude-leader",
                "gemini",
                std::slice::from_ref(event),
            )
            .expect("append folded batch");
    }

    // Rebuilt path: a single append of the whole batch takes the full-rebuild
    // branch.
    let rebuilt_db = DaemonDb::open_in_memory().expect("open rebuilt db");
    super::seed_conversation_session(&rebuilt_db);
    rebuilt_db
        .append_conversation_events(FOLD_SESSION_ID, "claude-leader", "gemini", &events)
        .expect("append rebuilt batch");

    assert_eq!(
        activity_json(&folded_db),
        activity_json(&rebuilt_db),
        "incremental fold must match a full rebuild"
    );

    let folded = leader_activity(&folded_db);
    assert_eq!(folded.tool_invocation_count, 3);
    assert_eq!(folded.latest_tool_name.as_deref(), Some("Edit"));
    assert_eq!(folded.recent_tools, vec!["Edit", "Read", "AskUserQuestion"]);
    let pending = folded
        .pending_user_prompt
        .expect("unresolved ask-user prompt must survive across fold batches");
    assert_eq!(pending.tool_name, "AskUserQuestion");
    assert_eq!(
        pending.waiting_since.as_deref(),
        Some("2026-04-03T12:00:01Z")
    );
}

#[test]
fn fold_clears_pending_prompt_when_result_arrives_in_later_batch() {
    let ask = ask_user_invocation(1, "2026-04-03T12:00:01Z", "ask-1");
    let answer = tool_result(2, "2026-04-03T12:00:02Z", "AskUserQuestion", "ask-1");

    let folded_db = DaemonDb::open_in_memory().expect("open folded db");
    super::seed_conversation_session(&folded_db);
    folded_db
        .append_conversation_events(
            FOLD_SESSION_ID,
            "claude-leader",
            "gemini",
            std::slice::from_ref(&ask),
        )
        .expect("append ask");
    assert!(
        leader_activity(&folded_db).pending_user_prompt.is_some(),
        "prompt is pending after the invocation batch"
    );

    folded_db
        .append_conversation_events(
            FOLD_SESSION_ID,
            "claude-leader",
            "gemini",
            std::slice::from_ref(&answer),
        )
        .expect("append answer");
    assert!(
        leader_activity(&folded_db).pending_user_prompt.is_none(),
        "result batch must clear the pending prompt through the fold path"
    );

    // The folded result equals a single-batch rebuild of the same two events.
    let rebuilt_db = DaemonDb::open_in_memory().expect("open rebuilt db");
    super::seed_conversation_session(&rebuilt_db);
    rebuilt_db
        .append_conversation_events(FOLD_SESSION_ID, "claude-leader", "gemini", &[ask, answer])
        .expect("append both");

    assert_eq!(activity_json(&folded_db), activity_json(&rebuilt_db));
}
