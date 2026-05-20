//! Tests for the in-daemon `OpenRouter` tool catalog and dispatcher.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;

use serde_json::json;
use tempfile::TempDir;

use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::acp::permission::PermissionMode;
use crate::agents::openrouter::{ToolCallDelta, ToolCallFunctionDelta};

use super::*;

#[test]
fn catalog_contains_all_seven_tools() {
    let catalog = tool_catalog();
    let names: Vec<_> = catalog
        .iter()
        .map(|tool| tool.function.name.as_str())
        .collect();
    assert_eq!(names.len(), 7, "expected seven tools, got {names:?}");
    assert!(names.contains(&TOOL_READ_TEXT_FILE));
    assert!(names.contains(&TOOL_WRITE_TEXT_FILE));
    assert!(names.contains(&TOOL_CREATE_TERMINAL));
    assert!(names.contains(&TOOL_TERMINAL_OUTPUT));
    assert!(names.contains(&TOOL_WAIT_FOR_TERMINAL_EXIT));
    assert!(names.contains(&TOOL_KILL_TERMINAL));
    assert!(names.contains(&TOOL_RELEASE_TERMINAL));
}

#[test]
fn absorb_delta_accumulates_arguments_across_chunks() {
    let mut accumulator: BTreeMap<u32, PartialToolCall> = BTreeMap::new();
    absorb_tool_call_delta(
        &mut accumulator,
        ToolCallDelta {
            index: 0,
            id: Some("call_a".to_owned()),
            kind: None,
            function: Some(ToolCallFunctionDelta {
                name: Some(TOOL_READ_TEXT_FILE.to_owned()),
                arguments: Some("{\"pa".to_owned()),
            }),
        },
    );
    absorb_tool_call_delta(
        &mut accumulator,
        ToolCallDelta {
            index: 0,
            id: None,
            kind: None,
            function: Some(ToolCallFunctionDelta {
                name: None,
                arguments: Some("th\":\"/tmp/x\"}".to_owned()),
            }),
        },
    );
    let finalized = finalize_tool_calls(accumulator);
    assert_eq!(finalized.len(), 1);
    let call = &finalized[0];
    assert_eq!(call.id, "call_a");
    assert_eq!(call.function.name, TOOL_READ_TEXT_FILE);
    assert_eq!(call.function.arguments, "{\"path\":\"/tmp/x\"}");
}

#[test]
fn finalize_orders_by_index() {
    let mut accumulator: BTreeMap<u32, PartialToolCall> = BTreeMap::new();
    accumulator.insert(
        2,
        PartialToolCall {
            id: "c".to_owned(),
            name: TOOL_TERMINAL_OUTPUT.to_owned(),
            arguments: "{}".to_owned(),
        },
    );
    accumulator.insert(
        0,
        PartialToolCall {
            id: "a".to_owned(),
            name: TOOL_READ_TEXT_FILE.to_owned(),
            arguments: "{}".to_owned(),
        },
    );
    accumulator.insert(
        1,
        PartialToolCall {
            id: "b".to_owned(),
            name: TOOL_WRITE_TEXT_FILE.to_owned(),
            arguments: "{}".to_owned(),
        },
    );
    let finalized = finalize_tool_calls(accumulator);
    let names: Vec<_> = finalized.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(names, vec!["a", "b", "c"]);
}

#[test]
fn dispatch_unknown_tool_returns_error_value() {
    let dir = TempDir::new().expect("tmpdir");
    let client = build_test_client(dir.path().to_path_buf());
    let result = dispatch_tool_call(
        &client,
        "session-1",
        &dir.path().to_path_buf(),
        "missing_tool",
        "{}",
    );
    assert!(
        result.get("error").is_some(),
        "expected error key in {result:?}"
    );
}

#[test]
fn dispatch_read_returns_file_content() {
    let dir = TempDir::new().expect("tmpdir");
    let target = dir.path().join("hello.txt");
    fs::write(&target, "hi there").expect("write");
    let client = build_test_client(dir.path().to_path_buf());
    let result = dispatch_tool_call(
        &client,
        "session-1",
        &dir.path().to_path_buf(),
        TOOL_READ_TEXT_FILE,
        &json!({ "path": target.to_string_lossy() }).to_string(),
    );
    assert_eq!(result["content"], "hi there");
}

#[test]
fn dispatch_read_outside_workspace_returns_error() {
    let dir = TempDir::new().expect("tmpdir");
    let outside = TempDir::new().expect("tmpdir-outside");
    let target = outside.path().join("escape.txt");
    fs::write(&target, "secret").expect("write");
    let client = build_test_client(dir.path().to_path_buf());
    let result = dispatch_tool_call(
        &client,
        "session-1",
        &dir.path().to_path_buf(),
        TOOL_READ_TEXT_FILE,
        &json!({ "path": target.to_string_lossy() }).to_string(),
    );
    assert!(
        result.get("error").is_some(),
        "expected error for path escape, got {result:?}"
    );
}

#[test]
fn dispatch_with_invalid_json_arguments_returns_error_value() {
    let dir = TempDir::new().expect("tmpdir");
    let client = build_test_client(dir.path().to_path_buf());
    let result = dispatch_tool_call(
        &client,
        "session-1",
        &dir.path().to_path_buf(),
        TOOL_READ_TEXT_FILE,
        "not-json",
    );
    let message = result["error"].as_str().expect("error key");
    assert!(
        message.contains("invalid arguments JSON"),
        "expected invalid-args message, got {message}"
    );
}

fn build_test_client(working_dir: std::path::PathBuf) -> HarnessAcpClient {
    let log_path = working_dir.join("permission-log.ndjson");
    HarnessAcpClient::new(
        working_dir.clone(),
        working_dir,
        None,
        BTreeSet::new(),
        PermissionMode::Recording { log_path },
    )
}
