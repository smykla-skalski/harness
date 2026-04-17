use std::path::Path;

use harness::agents::runtime::hook_agent_for_runtime_name;
use harness::agents::service::record_hook_event;
use harness::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use harness::hooks::protocol::result::NormalizedHookResult;
use harness::workspace::project_context_dir;

fn with_agent_storage_env(body: impl FnOnce(&Path)) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let data_dir = tmp.path().join("xdg_data");
    let project_dir = tmp.path().join("repo");
    std::fs::create_dir_all(&data_dir).expect("create xdg data dir");
    std::fs::create_dir_all(&project_dir).expect("create project dir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(data_dir.to_str().expect("xdg data path")),
            ),
            ("HOME", Some(tmp.path().to_str().expect("home path"))),
        ],
        || body(&project_dir),
    );
}

#[test]
fn gemini_lifecycle_transcript_uses_assistant_response_not_prompt_body() {
    with_agent_storage_env(|project_dir| {
        let context = NormalizedHookContext {
            event: NormalizedEvent::AgentStop,
            session: SessionContext {
                session_id: "gemini-real-session".into(),
                cwd: Some(project_dir.to_path_buf()),
                transcript_path: None,
            },
            tool: None,
            agent: Some(AgentContext {
                agent_id: None,
                agent_type: Some("gemini".into()),
                prompt: Some("/harness:harness session join sess-123 --role reviewer".into()),
                response: Some("actual assistant reply".into()),
            }),
            skill: SkillContext::inactive(),
            raw: RawPayload::new(serde_json::json!({
                "prompt": "/harness:harness session join sess-123 --role reviewer",
                "last_assistant_message": "actual assistant reply"
            })),
        };

        record_hook_event(
            hook_agent_for_runtime_name("gemini").expect("gemini hook agent"),
            "suite:run",
            "guard-stop",
            &context,
            &NormalizedHookResult::allow(),
        )
        .expect("record hook event");

        let transcript_path = project_context_dir(project_dir)
            .join("agents/sessions/gemini/gemini-real-session/raw.jsonl");
        let line = std::fs::read_to_string(&transcript_path)
            .expect("read transcript")
            .lines()
            .next()
            .expect("transcript line")
            .to_string();
        let payload: serde_json::Value = serde_json::from_str(&line).expect("parse transcript");
        assert_eq!(
            payload["message"]["content"][0]["text"].as_str(),
            Some("actual assistant reply")
        );
    });
}
