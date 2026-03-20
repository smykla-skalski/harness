use std::env;
use std::path::PathBuf;

use serde_json::Value;

use crate::hooks::protocol::context::{
    NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};

use super::GuardContext;

#[test]
fn from_normalized_hydrates_missing_session_cwd() {
    let context = GuardContext::from_normalized(NormalizedHookContext {
        event: NormalizedEvent::Notification,
        session: SessionContext {
            session_id: String::new(),
            cwd: None,
            transcript_path: None,
        },
        tool: None,
        agent: None,
        skill: SkillContext::inactive(),
        raw: RawPayload::new(Value::Null),
    });

    assert_eq!(
        context.session.cwd,
        Some(env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
    );
}
