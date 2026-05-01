use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::json;
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::task::JoinHandle;

use crate::mcp::automation::{AccessibilityQueryError, INPUT_OVERRIDE_ENV};
use crate::mcp::protocol::ContentBlock;
use crate::mcp::registry::RegistryClient;
use crate::mcp::registry::{
    ElementKind, GetElementResult, ListElementsResult, Rect, RegistryElement,
};
use crate::mcp::tool::Tool;
use crate::workspace::socket_paths::session_socket;

use super::shared::{resolve_get_element_with, resolve_list_elements_with};
use super::{
    ClickElementTool, DragDropTool, GetElementTool, ListElementsTool, ListWindowsTool,
    PressElementTool, ScrollTool, register_all,
};

mod interaction_tests;
mod registry_tool_tests;

fn socket_path(dir: &TempDir) -> PathBuf {
    session_socket(dir.path(), "testid00", "registry")
}

fn spawn_single_response(path: &Path, response: String) -> JoinHandle<String> {
    let listener = UnixListener::bind(path).expect("bind");
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader.read_line(&mut line).await.expect("read line");
        let mut payload = response.into_bytes();
        payload.push(b'\n');
        write.write_all(&payload).await.expect("write");
        write.shutdown().await.ok();
        line
    })
}

fn spawn_response_sequence(path: &Path, responses: Vec<String>) -> JoinHandle<Vec<String>> {
    let listener = UnixListener::bind(path).expect("bind");
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::new(read);
        let mut lines = Vec::with_capacity(responses.len());
        for response in responses {
            let mut line = String::new();
            reader.read_line(&mut line).await.expect("read line");
            lines.push(line);
            let mut payload = response.into_bytes();
            payload.push(b'\n');
            write.write_all(&payload).await.expect("write");
        }
        write.shutdown().await.ok();
        lines
    })
}

fn sample_element_response(id: u64) -> String {
    sample_element_response_with(id, "button.send", 100.0, 200.0, 60.0, 40.0)
}

fn sample_element_response_with(
    id: u64,
    identifier: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> String {
    sample_element_response_with_enabled(id, identifier, x, y, width, height, true)
}

fn sample_element_response_with_enabled(
    id: u64,
    identifier: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    enabled: bool,
) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"element": {
            "identifier": identifier,
            "label": identifier,
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": x, "y": y, "width": width, "height": height},
            "windowID": 7,
            "enabled": enabled,
            "selected": false,
            "focused": true,
        }}
    })
    .to_string()
}

fn actionable_element_response(id: u64, identifier: &str) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"element": {
            "identifier": identifier,
            "label": identifier,
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": 100.0, "y": 200.0, "width": 60.0, "height": 40.0},
            "windowID": 7,
            "enabled": true,
            "selected": false,
            "focused": true,
            "actions": ["press"],
        }}
    })
    .to_string()
}

fn empty_elements_response(id: u64) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"elements": []},
    })
    .to_string()
}

fn elements_response(id: u64, identifier: &str, window_id: i64) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"elements": [{
            "identifier": identifier,
            "label": "Fallback",
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": 10.0, "y": 20.0, "width": 30.0, "height": 40.0},
            "windowID": window_id,
            "enabled": true,
            "selected": false,
            "focused": false,
        }]},
    })
    .to_string()
}

fn not_found_response(id: u64) -> String {
    json!({
        "id": id,
        "ok": false,
        "error": {"code": "not-found", "message": "no element"},
    })
    .to_string()
}

fn fallback_element(identifier: &str, window_id: i64, kind: ElementKind) -> RegistryElement {
    RegistryElement {
        identifier: identifier.to_string(),
        label: Some("Fallback".to_string()),
        value: None,
        hint: None,
        kind,
        frame: Rect {
            x: 10.0,
            y: 20.0,
            width: 30.0,
            height: 40.0,
        },
        window_id: Some(window_id),
        enabled: true,
        selected: false,
        focused: false,
        actions: vec![],
    }
}

fn write_helper_script(path: &Path, body: &str) {
    fs::write(path, body).expect("write helper");
    let mut permissions = fs::metadata(path).expect("helper metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).expect("set helper executable");
}

fn write_fake_harness_input(path: &Path) {
    let script = r#"#!/bin/sh
case "$1" in
  --help|check)
    exit 0
    ;;
  get-element)
    identifier="$2"
    case "$identifier" in
      "task.source")
        x=10
        y=20
        width=50
        height=40
        ;;
      "agent.destination")
        x=210
        y=120
        width=60
        height=60
        ;;
      *)
        x=10
        y=20
        width=30
        height=40
        ;;
    esac
    printf '{"element":{"identifier":"%s","label":"%s","value":null,"hint":null,"kind":"button","frame":{"x":%s,"y":%s,"width":%s,"height":%s},"windowID":7,"enabled":true,"selected":false,"focused":true}}\n' \
      "$identifier" "$identifier" "$x" "$y" "$width" "$height"
    ;;
  scroll|drag|perform-action)
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
"#;
    write_helper_script(path, script);
}

fn write_press_action_helper(path: &Path, log_path: &Path) {
    let script = format!(
        r#"#!/bin/sh
case "$1" in
  --help|check)
    exit 0
    ;;
  perform-action)
    printf '%s\n' "$*" >> "{log_path}"
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
"#,
        log_path = log_path.to_string_lossy()
    );
    write_helper_script(path, &script);
}

fn write_press_action_failure_helper(path: &Path, exit_code: i32, stderr: &str) {
    let script = format!(
        r#"#!/bin/sh
case "$1" in
  --help|check)
    exit 0
    ;;
  perform-action)
    printf '%s\n' "{stderr}" >&2
    exit {exit_code}
    ;;
  *)
    exit 64
    ;;
esac
"#
    );
    write_helper_script(path, &script);
}
