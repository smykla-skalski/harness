use super::*;

fn assert_notify_context(context: &NormalizedHookContext) {
    assert_eq!(context.event, NormalizedEvent::Notification);
    assert_eq!(context.session.session_id, "session-123");
    assert_eq!(context.session.cwd, Some(PathBuf::from("/tmp/project")));
    let tool = context.tool.as_ref().expect("expected tool");
    assert_eq!(tool.original_name, CODEX_TURN_TOOL_NAME);
    assert_eq!(
        tool.input_raw["input_messages"][0],
        Value::String("run the suite".into())
    );
    let response = tool.response.as_ref().expect("expected response");
    assert_eq!(
        response["last_assistant_message"],
        Value::String("done".into())
    );
}

fn assert_notify_agent(context: &NormalizedHookContext) {
    let agent = context.agent.as_ref().expect("expected agent");
    assert_eq!(agent.agent_id.as_deref(), Some("turn-456"));
    assert_eq!(agent.agent_type.as_deref(), Some(CODEX_TURN_AGENT_TYPE));
    assert_eq!(agent.response.as_deref(), Some("done"));
}

#[test]
fn parse_notify_payload_into_notification_context() {
    let adapter = CodexAdapter;
    let raw = br#"{
        "type":"agent-turn-complete",
        "thread-id":"session-123",
        "turn-id":"turn-456",
        "cwd":"/tmp/project",
        "input-messages":["run the suite","report failures"],
        "last-assistant-message":"done"
    }"#
    .to_vec();

    let context = adapter.parse_input(&raw).unwrap();
    assert_notify_context(&context);
    assert_notify_agent(&context);
}

#[test]
fn parse_local_shell_payload_maps_to_shell_tool() {
    let adapter = CodexAdapter;
    let raw = br#"{
        "session_id":"session-123",
        "cwd":"/tmp/project",
        "hook_event_name":"PreToolUse",
        "tool_name":"local_shell",
        "tool_input":{
            "input_type":"local_shell",
            "params":{
                "command":["cargo","test","--lib"]
            }
        }
    }"#
    .to_vec();

    let context = adapter.parse_input(&raw).unwrap();
    let tool = context.tool.as_ref().expect("expected tool");

    assert_eq!(context.event, NormalizedEvent::BeforeToolUse);
    assert_eq!(tool.category, ToolCategory::Shell);
    assert_eq!(tool.input.command_text(), Some("cargo test --lib"));
}

#[test]
fn parse_user_prompt_submit_extracts_nested_prompt_and_turn_id() {
    let adapter = CodexAdapter;
    let raw = br#"{
        "session_id":"session-123",
        "turn_id":"turn-456",
        "cwd":"/tmp/project",
        "hook_event_name":"UserPromptSubmit",
        "event":{"user_prompt":"continue observing from codex"}
    }"#
    .to_vec();

    let context = adapter.parse_input(&raw).unwrap();
    let agent = context.agent.as_ref().expect("expected agent");

    assert_eq!(context.event, NormalizedEvent::UserPromptSubmit);
    assert_eq!(agent.agent_id.as_deref(), Some("turn-456"));
    assert_eq!(
        agent.prompt.as_deref(),
        Some("continue observing from codex")
    );
}

#[test]
fn codex_config_names_match_current_lifecycle_events() {
    let adapter = CodexAdapter;

    assert_eq!(
        adapter.event_name(&NormalizedEvent::UserPromptSubmit),
        Some("UserPromptSubmit")
    );
    assert_eq!(
        adapter.event_name(&NormalizedEvent::BeforeToolUse),
        Some("PreToolUse")
    );
    assert_eq!(
        adapter.event_name(&NormalizedEvent::AfterToolUse),
        Some("PostToolUse")
    );
    assert_eq!(
        adapter.event_name(&NormalizedEvent::SessionStart),
        Some("SessionStart")
    );
    assert_eq!(
        adapter.event_name(&NormalizedEvent::BeforeCompaction),
        Some("PreCompact")
    );
    assert_eq!(
        adapter.event_name(&NormalizedEvent::SessionEnd),
        Some("SessionEnd")
    );
    assert_eq!(
        adapter.event_name(&NormalizedEvent::SubagentStop),
        Some("SubagentStop")
    );
}
