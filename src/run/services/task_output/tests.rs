use super::extract_text_content;

#[test]
fn extract_plain_text_line() {
    let lines = extract_text_content("2026-03-15T18:26:53Z cluster: starting single-up");
    assert_eq!(
        lines,
        vec!["2026-03-15T18:26:53Z cluster: starting single-up"]
    );
}

#[test]
fn extract_empty_line() {
    let lines = extract_text_content("");
    assert!(lines.is_empty());
}

#[test]
fn extract_whitespace_only_line() {
    let lines = extract_text_content("   ");
    assert!(lines.is_empty());
}

#[test]
fn extract_assistant_text_content() {
    let jsonl = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I found the issue."},{"type":"text","text":"The fix is straightforward."}]}}"#;
    let lines = extract_text_content(jsonl);
    assert_eq!(
        lines,
        vec!["I found the issue.", "The fix is straightforward."]
    );
}

#[test]
fn extract_skips_tool_use_in_content() {
    let jsonl = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"ls"}},{"type":"text","text":"Here are the files."}]}}"#;
    let lines = extract_text_content(jsonl);
    assert_eq!(lines, vec!["Here are the files."]);
}

#[test]
fn extract_skips_user_messages() {
    let jsonl = r#"{"type":"user","message":{"role":"user","content":"Do something"}}"#;
    let lines = extract_text_content(jsonl);
    assert!(lines.is_empty());
}
