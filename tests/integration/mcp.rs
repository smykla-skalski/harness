//! End-to-end MCP stdio server tests. Spawn `harness mcp serve`, send
//! JSON-RPC frames over stdin, read responses from stdout.

use std::fs;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use assert_cmd::cargo::cargo_bin;
use serde_json::{Value, json};
use tempfile::TempDir;

fn spawn_server() -> std::process::Child {
    spawn_server_with_env(&[])
}

fn spawn_server_with_env(envs: &[(&str, &Path)]) -> std::process::Child {
    let mut command = Command::new(cargo_bin("harness"));
    command
        .args(["mcp", "serve"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for (key, value) in envs {
        command.env(key, value);
    }
    command.spawn().expect("spawn harness mcp serve")
}

fn write_helper_script(dir: &TempDir) -> (PathBuf, PathBuf) {
    let helper_path = dir.path().join("fake-helper.sh");
    let log_path = dir.path().join("helper.log");
    fs::write(
        &helper_path,
        format!(
            "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> \"{}\"\n",
            log_path.display()
        ),
    )
    .expect("write helper");
    let mut permissions = fs::metadata(&helper_path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&helper_path, permissions).expect("chmod helper");
    (helper_path, log_path)
}

fn spawn_registry_server(path: &Path, responses: Vec<Value>) -> thread::JoinHandle<Vec<String>> {
    let listener = UnixListener::bind(path).expect("bind registry socket");
    thread::spawn(move || {
        let (stream, _) = listener.accept().expect("accept registry connection");
        let read = stream.try_clone().expect("clone registry stream");
        let mut reader = BufReader::new(read);
        let mut writer = BufWriter::new(stream);
        let mut requests = Vec::new();
        for response in responses {
            let mut line = String::new();
            reader.read_line(&mut line).expect("read registry request");
            requests.push(line);
            writer
                .write_all(response.to_string().as_bytes())
                .expect("write registry response");
            writer.write_all(b"\n").expect("write registry newline");
            writer.flush().expect("flush registry response");
        }
        requests
    })
}

fn sample_element_response(
    id: u64,
    identifier: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Value {
    json!({
        "id": id,
        "ok": true,
        "result": {"element": {
            "identifier": identifier,
            "label": identifier,
            "value": null,
            "hint": null,
            "kind": "row",
            "frame": {"x": x, "y": y, "width": width, "height": height},
            "windowID": 7,
            "enabled": true,
            "selected": false,
            "focused": false
        }}
    })
}

fn read_helper_log(path: &Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Ok(contents) = fs::read_to_string(path)
            && !contents.trim().is_empty()
        {
            return contents;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for helper log"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

fn call_tool(child: &mut std::process::Child, id: i64, name: &str, arguments: Value) {
    send(
        child,
        &json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": {
                "name": name,
                "arguments": arguments,
            },
        }),
    );
}

#[cfg(target_os = "macos")]
fn initialize_server(
    child: &mut std::process::Child,
    reader: &mut BufReader<&mut std::process::ChildStdout>,
) {
    send(
        child,
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
    let _ = read_response_with_id(reader, 1);
}

#[cfg(target_os = "macos")]
fn shutdown_server(
    mut child: std::process::Child,
    reader: BufReader<&mut std::process::ChildStdout>,
) {
    drop(reader);
    drop(child.stdin.take());
    let _ = child.wait().expect("wait child");
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
fn mcp_serve_initialize_lists_all_registered_tools() {
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
            "press_element",
            "scroll",
            "drag_drop",
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
fn mcp_scroll_reaches_real_cockpit_scroll_target() {
    let dir = TempDir::new().expect("tempdir");
    let socket_path = dir.path().join("registry.sock");
    let (helper_path, helper_log) = write_helper_script(&dir);
    let registry = spawn_registry_server(
        &socket_path,
        vec![sample_element_response(
            1,
            "harness.session.cockpit.scroll",
            10.0,
            20.0,
            200.0,
            120.0,
        )],
    );
    let mut child = spawn_server_with_env(&[
        ("HARNESS_MONITOR_MCP_SOCKET", &socket_path),
        ("HARNESS_MONITOR_INPUT_BIN", &helper_path),
    ]);
    let mut stdout = child.stdout.take().expect("take stdout");
    let mut reader = BufReader::new(&mut stdout);
    initialize_server(&mut child, &mut reader);

    call_tool(
        &mut child,
        2,
        "scroll",
        json!({
            "identifier": "harness.session.cockpit.scroll",
            "deltaY": 180,
        }),
    );
    let response = read_response_with_id(&mut reader, 2);
    assert_eq!(
        response.pointer("/result/isError"),
        Some(&Value::Bool(false))
    );
    assert!(
        read_helper_log(&helper_log).contains("scroll 110 80 0 180"),
        "unexpected helper log: {}",
        read_helper_log(&helper_log)
    );
    let requests = registry.join().expect("registry thread");
    assert_eq!(requests.len(), 1);
    assert!(requests[0].contains("\"identifier\":\"harness.session.cockpit.scroll\""));

    shutdown_server(child, reader);
}

#[cfg(target_os = "macos")]
#[test]
fn mcp_drag_drop_reaches_real_task_to_agent_path() {
    let dir = TempDir::new().expect("tempdir");
    let socket_path = dir.path().join("registry.sock");
    let (helper_path, helper_log) = write_helper_script(&dir);
    let source = "harness.session.task.task-drop-queue";
    let destination = "harness.session.agent.worker-codex";
    let registry = spawn_registry_server(
        &socket_path,
        vec![
            sample_element_response(1, source, 10.0, 20.0, 50.0, 40.0),
            sample_element_response(2, destination, 210.0, 120.0, 60.0, 60.0),
        ],
    );
    let mut child = spawn_server_with_env(&[
        ("HARNESS_MONITOR_MCP_SOCKET", &socket_path),
        ("HARNESS_MONITOR_INPUT_BIN", &helper_path),
    ]);
    let mut stdout = child.stdout.take().expect("take stdout");
    let mut reader = BufReader::new(&mut stdout);
    initialize_server(&mut child, &mut reader);

    call_tool(
        &mut child,
        2,
        "drag_drop",
        json!({
            "sourceIdentifier": source,
            "destinationIdentifier": destination,
            "durationMs": 180,
        }),
    );
    let response = read_response_with_id(&mut reader, 2);
    assert_eq!(
        response.pointer("/result/isError"),
        Some(&Value::Bool(false))
    );
    assert!(
        read_helper_log(&helper_log).contains("drag 35 40 240 150 --duration-ms 180"),
        "unexpected helper log: {}",
        read_helper_log(&helper_log)
    );
    let requests = registry.join().expect("registry thread");
    assert_eq!(requests.len(), 2);
    assert!(requests[0].contains(&format!("\"identifier\":\"{source}\"")));
    assert!(requests[1].contains(&format!("\"identifier\":\"{destination}\"")));

    shutdown_server(child, reader);
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
