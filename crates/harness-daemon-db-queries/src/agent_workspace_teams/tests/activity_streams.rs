use harness_protocol::agent::{ConversationEvent, ConversationEventKind};
use sqlx::query;

use super::super::AsyncAgentWorkspaceTeamQueries;
use super::support::{DAEMON_ID, Fixture, NOW};
use crate::{AsyncAgentWorkspaceActivityQueries, AsyncAgentWorkspaceQueries};

#[tokio::test]
async fn merged_member_preserves_each_legacy_conversation_stream() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-activity-streams", "session-activity-streams")
        .await;
    for agent_id in ["agent-stream-a", "agent-stream-b"] {
        fixture
            .seed_agent(
                "session-activity-streams",
                agent_id,
                "acp",
                "acp-shared",
                "runtime-shared",
            )
            .await;
    }
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile workspace");
    let team = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile merged durable member")
        .team
        .expect("durable team");
    assert_eq!(team.members.len(), 1);
    let member_id = &team.members[0].member_id;

    for agent_id in ["agent-stream-b", "agent-stream-a"] {
        let event = ConversationEvent {
            timestamp: Some(NOW.to_string()),
            sequence: 1,
            kind: ConversationEventKind::AssistantText {
                content: agent_id.to_string(),
                message_id: None,
            },
            agent: agent_id.to_string(),
            session_id: "session-activity-streams".to_string(),
        };
        query(
            "INSERT INTO conversation_events (
                session_id, agent_id, runtime, timestamp, sequence, kind, event_json
             ) VALUES ('session-activity-streams', ?1, 'acp', ?2, 1,
                       'assistant_text', ?3)",
        )
        .bind(agent_id)
        .bind(NOW)
        .bind(serde_json::to_string(&event).expect("serialize conversation event"))
        .execute(fixture.db.pool())
        .await
        .expect("insert legacy conversation event");
    }

    let activity = fixture
        .db
        .load_agent_workspace_member_activity(DAEMON_ID, &workspace_id, member_id)
        .await
        .expect("load merged member activity");
    assert_eq!(activity.conversation.len(), 2);
    assert_eq!(activity.conversation[0].event.agent, "agent-stream-a");
    assert_eq!(activity.conversation[1].event.agent, "agent-stream-b");
    assert_eq!(activity.conversation[0].owner.id, *member_id);
    assert_eq!(activity.conversation[1].owner.id, *member_id);
}
