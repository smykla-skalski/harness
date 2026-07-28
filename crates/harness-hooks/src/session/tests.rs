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
fn resolve_cwd_uses_payload_when_present() {
    let result = resolve_cwd("/from/payload", Path::new("/fallback"));
    assert_eq!(result, PathBuf::from("/from/payload"));
}

#[test]
fn resolve_cwd_falls_back_to_project_dir() {
    let result = resolve_cwd("", Path::new("/project"));
    assert_eq!(result, PathBuf::from("/project"));
}
