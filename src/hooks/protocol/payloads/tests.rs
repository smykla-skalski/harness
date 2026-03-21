use std::path::Path;

use super::*;
use crate::hooks::application::GuardContext;

#[test]
fn envelope_from_str_parses() {
    let json = r#"{"tool_name": "Read", "tool_input": {"file_path": "/workspace/file.txt"}}"#;
    let envelope: HookEnvelopePayload = json.parse().unwrap();
    assert_eq!(envelope.tool_name, "Read");
    assert_eq!(envelope.tool_input["file_path"], "/workspace/file.txt");
}

#[test]
fn envelope_from_str_invalid() {
    let result = "not json".parse::<HookEnvelopePayload>();
    assert!(result.is_err());
}

#[test]
fn envelope_from_json_empty_object() {
    let envelope = HookEnvelopePayload::from_json_text("{}").unwrap();
    assert!(envelope.tool_name.is_empty());
    assert_eq!(envelope.tool_input, Value::Null);
    assert_eq!(envelope.tool_response, Value::Null);
    assert!(!envelope.stop_hook_active);
    assert!(envelope.raw_keys.is_empty());
}

#[test]
fn envelope_from_json_with_command() {
    let json = r#"{"tool_name": "Bash", "tool_input": {"command": "kubectl get pods"}}"#;
    let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
    assert_eq!(envelope.tool_name, "Bash");
    assert_eq!(envelope.tool_input["command"], "kubectl get pods");
}

#[test]
fn envelope_from_json_with_questions() {
    let json = r#"{
        "tool_name": "AskUserQuestion",
        "tool_input": {
            "questions": [{
                "question": "Install validator?",
                "options": [
                    {"label": "Yes", "description": "Install it"},
                    {"label": "No", "description": "Skip"}
                ]
            }]
        }
    }"#;
    let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
    let context = GuardContext::from_test_envelope("suite:run", envelope);
    let prompts = context.question_prompts();
    assert_eq!(prompts.len(), 1);
    let prompt = &prompts[0];
    assert_eq!(prompt.question, "Install validator?");
    assert_eq!(prompt.option_labels(), vec!["Yes", "No"]);
    assert_eq!(prompt.question_head(), "Install validator?");
}

#[test]
fn envelope_from_json_invalid() {
    let result = HookEnvelopePayload::from_json_text("not json");
    assert!(result.is_err());
    let error = result.unwrap_err();
    assert_eq!(error.code(), "KSH001");
    assert!(error.message().contains("invalid hook payload"));
}

#[test]
fn envelope_from_json_full_envelope() {
    let json = r#"{
        "tool_name": "Agent",
        "tool_input": {"description": "run preflight"},
        "transcript_path": "/tmp/transcript.json",
        "stop_hook_active": true,
        "raw_keys": ["key1", "key2"]
    }"#;
    let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
    assert_eq!(envelope.tool_name, "Agent");
    assert_eq!(
        envelope.transcript_path.as_deref(),
        Some(Path::new("/tmp/transcript.json"))
    );
    assert!(envelope.stop_hook_active);
    assert_eq!(envelope.raw_keys, vec!["key1", "key2"]);
}

#[test]
fn context_from_envelope_sets_skill() {
    let payload = HookEnvelopePayload::from_json_text("{}").unwrap();
    let context = GuardContext::from_test_envelope("suite:run", payload);
    assert_eq!(context.skill.name.as_deref(), Some("suite:run"));
    assert!(context.skill_active);
    assert_eq!(context.skill.name.as_deref(), Some("suite:run"));
}

#[test]
fn question_head_returns_first_line() {
    let prompt = AskUserQuestionPrompt {
        question: "First line\nSecond line\nThird".to_string(),
        header: None,
        options: vec![],
        multi_select: false,
    };
    assert_eq!(prompt.question_head(), "First line");
}

#[test]
fn response_text_renders_bash_output() {
    let json = r#"{
        "tool_name": "Bash",
        "tool_response": {"stdout": "ok", "stderr": "warn", "exit_code": 3}
    }"#;
    let payload = HookEnvelopePayload::from_json_text(json).unwrap();
    let context = GuardContext::from_test_envelope("suite:run", payload);
    assert_eq!(
        context.response_text(),
        "exit code: 3\n--- STDOUT ---\nok\n--- STDERR ---\nwarn"
    );
}

#[test]
fn response_text_returns_empty_when_absent() {
    let payload = HookEnvelopePayload::from_json_text("{}").unwrap();
    let context = GuardContext::from_test_envelope("suite:run", payload);
    assert_eq!(context.response_text(), "");
}

#[test]
fn response_text_renders_non_bash_json() {
    let json = r#"{
        "tool_name": "AskUserQuestion",
        "tool_response": {"answers": [{"question": "Q", "answer": "A"}]}
    }"#;
    let payload = HookEnvelopePayload::from_json_text(json).unwrap();
    let context = GuardContext::from_test_envelope("suite:run", payload);
    assert!(context.response_text().contains("\"answer\": \"A\""));
}
