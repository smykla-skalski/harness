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
