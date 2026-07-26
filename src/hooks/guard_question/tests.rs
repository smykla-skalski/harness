use super::*;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;

fn ctx_with_questions(skill: &str, questions: &serde_json::Value) -> HookContext {
    HookContext::from_envelope(
        skill,
        HookEnvelopePayload {
            tool_name: "AskUserQuestion".to_string(),
            tool_input: serde_json::json!({ "questions": questions }),
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    )
}

#[test]
fn allows_context_without_prompts() {
    let ctx = ctx_with_questions("suite:run", &serde_json::json!([]));
    assert_eq!(execute(&ctx).unwrap().decision, Decision::Allow);
}

#[test]
fn allows_suite_runner_prompts() {
    let ctx = ctx_with_questions(
        "suite:run",
        &serde_json::json!([{
            "question": "how should this failure be handled?",
            "options": [],
        }]),
    );
    assert_eq!(execute(&ctx).unwrap().decision, Decision::Allow);
}
