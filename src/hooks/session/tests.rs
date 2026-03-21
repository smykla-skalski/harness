use super::*;

#[test]
fn session_start_output_from_additional_context() {
    let output = SessionStartHookOutput::from_additional_context("hello world");
    assert_eq!(output.hook_specific_output.hook_event_name, "SessionStart");
    assert_eq!(
        output.hook_specific_output.additional_context,
        "hello world"
    );
}

#[test]
fn session_start_output_to_json_has_camel_case_keys() {
    let output = SessionStartHookOutput::from_additional_context("ctx");
    let json = output.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(
        parsed["hookSpecificOutput"]["hookEventName"],
        "SessionStart"
    );
    assert_eq!(parsed["hookSpecificOutput"]["additionalContext"], "ctx");
}

#[test]
fn session_start_output_roundtrips_json() {
    let output = SessionStartHookOutput::from_additional_context("round trip");
    let json = output.to_json().unwrap();
    let parsed: SessionStartHookOutput = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed, output);
}

#[test]
fn session_start_input_deserializes_from_json() {
    let json = r#"{"source":"compact","session_id":"abc","cwd":"/tmp"}"#;
    let input: SessionStartHookInput = serde_json::from_str(json).unwrap();
    assert_eq!(input.source, "compact");
    assert_eq!(input.session_id, "abc");
    assert_eq!(input.cwd, "/tmp");
    assert!(input.raw_keys.is_empty());
}

#[test]
fn session_start_input_defaults_missing_fields() {
    let input: SessionStartHookInput = serde_json::from_str("{}").unwrap();
    assert!(input.source.is_empty());
    assert!(input.session_id.is_empty());
    assert!(input.cwd.is_empty());
    assert!(input.transcript_path.is_none());
}

#[test]
fn pre_compact_input_deserializes_from_json() {
    let json = r#"{"trigger":"manual","session_id":"s1","cwd":"/repo"}"#;
    let input: PreCompactHookInput = serde_json::from_str(json).unwrap();
    assert_eq!(input.trigger, "manual");
    assert_eq!(input.session_id, "s1");
    assert!(input.custom_instructions.is_none());
}

#[test]
fn resolve_cwd_uses_payload_when_present() {
    let result = resolve_cwd("/from/payload", Path::new("/fallback"));
    assert_eq!(result, PathBuf::from("/from/payload"));
}

#[test]
fn resolve_cwd_falls_back_to_project_dir() {
    let result = resolve_cwd("", Path::new("/project"));
    assert_eq!(result, PathBuf::from("/project"));
}
