use std::env;
use std::path::PathBuf;

use serde_json::Value;

use crate::hooks::protocol::context::{
    NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::kernel::skills::SKILL_RUN;

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
        Some(expected.canonicalize().unwrap_or(expected))
    );
}

#[test]
fn skill_active_false_when_no_session_run_context() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("no-run-session")),
        ],
        || {
            let context = GuardContext::from_normalized(NormalizedHookContext {
                event: NormalizedEvent::BeforeToolUse,
                session: SessionContext {
                    session_id: "no-run-session".to_string(),
                    cwd: Some(tmp.path().to_path_buf()),
                    transcript_path: None,
                },
                tool: None,
                agent: None,
                skill: SkillContext::from_skill_name(SKILL_RUN),
                raw: RawPayload::new(Value::Null),
            });

            // The CLI claims suite:run but there is no run pointer in this
            // session, so skill_active must be false. This prevents
            // project-level hooks from blocking unrelated sessions.
            assert!(
                !context.skill_active,
                "skill_active should be false when session has no run context"
            );
            // The skill kind should still record what the CLI claimed, even
            // though the skill is not active.
            assert!(context.skill.is_runner());
        },
    );
}
