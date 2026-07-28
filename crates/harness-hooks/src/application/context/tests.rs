use std::env;
use std::path::PathBuf;

use serde_json::Value;

use crate::protocol::context::{
    NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use harness_workspace::workspace::canonical_checkout_root;

use super::GuardContext;

// `hydrate_session` resolves a missing/relative cwd to the git checkout
// root, not the raw working directory, so the expected value here must go
// through the same `canonical_checkout_root` call: the test process's own
// cwd is this crate's package directory (`crates/harness-hooks`), a
// subdirectory of the checkout the production code actually reports.
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

    let expected = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    assert_eq!(
        context.session.cwd,
        Some(canonical_checkout_root(&expected))
    );
}

#[test]
fn from_normalized_canonicalizes_relative_session_cwd() {
    let expected = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));

    let context = GuardContext::from_normalized(NormalizedHookContext {
        event: NormalizedEvent::Notification,
        session: SessionContext {
            session_id: String::new(),
            cwd: Some(PathBuf::from(".")),
            transcript_path: None,
        },
        tool: None,
        agent: None,
        skill: SkillContext::inactive(),
        raw: RawPayload::new(Value::Null),
    });

    assert_eq!(
        context.session.cwd,
        Some(canonical_checkout_root(&expected))
    );
}
