//! End-to-end MCP stdio server tests. Spawn `harness mcp serve`, send
//! JSON-RPC frames over stdin, read responses from stdout.

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use assert_cmd::cargo::cargo_bin;
use serde_json::{Value, json};

fn spawn_server() -> std::process::Child {
    Command::new(cargo_bin("harness"))
        .args(["mcp", "serve"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn harness mcp serve")
}

fn send(child: &mut std::process::Child, value: &Value) {
    let payload = format!("{value}\n");
    child
        .stdin
        .as_mut()
        .expect("stdin")
        .write_all(payload.as_bytes())
        .expect("write stdin");
}

fn read_response_with_id(
    reader: &mut BufReader<&mut std::process::ChildStdout>,
    expected_id: i64,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for response id {expected_id}",
        );
        let mut line = String::new();
        let bytes = reader.read_line(&mut line).expect("read stdout");
        assert!(bytes > 0, "server closed stdout before id {expected_id}");
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let parsed: Value = serde_json::from_str(trimmed).expect("parse response");
        if parsed.get("id").and_then(Value::as_i64) == Some(expected_id) {
            return parsed;
        }
    }
}

#[cfg(target_os = "macos")]
#[test]
fn mcp_serve_initialize_lists_all_eight_tools() {
    let mut child = spawn_server();
    let mut stdout = child.stdout.take().expect("take stdout");
    let mut reader = BufReader::new(&mut stdout);

    send(
        &mut child,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "clientInfo": {"name": "harness-it", "version": "0.0.1"},
                "capabilities": {},
            },
        }),
    );
    let init = read_response_with_id(&mut reader, 1);
    assert_eq!(
        init.pointer("/result/protocolVersion").unwrap(),
        "2025-11-25",
    );
    assert!(init.pointer("/result/capabilities/tools").is_some());

    send(
        &mut child,
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
    );
    let list = read_response_with_id(&mut reader, 2);
    let tools = list
        .pointer("/result/tools")
        .and_then(Value::as_array)
        .expect("tools array");
    let names: Vec<&str> = tools
        .iter()
        .filter_map(|t| t.get("name").and_then(Value::as_str))
        .collect();
    assert_eq!(
        names,
        vec![
            "list_windows",
            "list_elements",
            "get_element",
            "move_mouse",
            "click",
            "click_element",
            "type_text",
            "screenshot_window",
        ],
    );

    drop(reader);
    drop(stdout);
    drop(child.stdin.take());
    let _ = child.wait().expect("wait child");
}

#[cfg(target_os = "macos")]
#[test]
fn mcp_serve_unknown_method_returns_method_not_found() {
    let mut child = spawn_server();
    let mut stdout = child.stdout.take().expect("take stdout");
    let mut reader = BufReader::new(&mut stdout);

    send(
        &mut child,
        &json!({"jsonrpc":"2.0","id":5,"method":"bogus","params":{}}),
    );
    let response = read_response_with_id(&mut reader, 5);
    assert_eq!(response.pointer("/error/code").unwrap(), -32601);

    drop(reader);
    drop(stdout);
    drop(child.stdin.take());
    let _ = child.wait();
}

#[cfg(not(target_os = "macos"))]
#[test]
fn mcp_serve_non_macos_refuses_with_workflow_io_error() {
    let output = Command::new(cargo_bin("harness"))
        .args(["mcp", "serve"])
        .output()
        .expect("run harness mcp serve");
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("requires macOS"),
        "expected macOS refusal, got stderr: {stderr}",
    );
}
