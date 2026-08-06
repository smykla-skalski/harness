use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{DaemonDb, DaemonDbConversation};
use crate::daemon::db_handle::DaemonDbOwnedHandle;
use crate::daemon::http::DaemonHttpState;

pub(super) fn seed_sample_acp_transcript(state: &DaemonHttpState) {
    let db_path = state.db_path.as_ref().expect("db path");
    let db = DaemonDb::open(db_path).expect("open file db");
    let db = DaemonDbOwnedHandle(db);
    let mut session = db
        .load_session_state("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
        .expect("load sample session")
        .expect("sample session present");
    let agent = session
        .agents
        .get_mut("codex-worker")
        .expect("sample codex worker present");
    agent.runtime = "gemini".into();
    agent.managed_agent = Some(crate::session::types::ManagedAgentRef::acp("acp-agent-1"));
    db.save_session_state("project-abc123", &session)
        .expect("save managed ACP session");
    db.sync_conversation_events(
        "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
        "codex-worker",
        "gemini",
        &[ConversationEvent {
            timestamp: Some("2026-04-13T19:03:00Z".into()),
            sequence: 7,
            kind: ConversationEventKind::AssistantText {
                content: "ACP transcript line".into(),
                message_id: None,
            },
            agent: "codex-worker".into(),
            session_id: "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into(),
        }],
    )
    .expect("sync ACP conversation events");
}
