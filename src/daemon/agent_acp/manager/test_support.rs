use std::fs;
use std::path::Path;

#[cfg(unix)]
pub(super) fn write_executable(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;

    fs::write(path, body).expect("write script");
    let mut permissions = fs::metadata(path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).expect("chmod script");
}

#[cfg(unix)]
pub(super) fn write_sleeping_acp_agent(path: &Path) {
    write_executable(path, &fake_acp_agent_script(None, None, None));
}

#[cfg(unix)]
pub(super) fn write_cancel_recording_acp_agent(path: &Path, cancel_log: &Path) {
    write_executable(path, &fake_acp_agent_script(None, None, Some(cancel_log)));
}

#[cfg(unix)]
pub(super) fn write_prompt_delaying_acp_agent(path: &Path, delay_seconds: f32) {
    write_executable(
        path,
        &fake_acp_agent_script(None, Some(delay_seconds), None),
    );
}

#[cfg(unix)]
pub(super) fn write_exiting_acp_agent(path: &Path, delay_seconds: f32, code: i32) {
    write_executable(
        path,
        &fake_acp_agent_script(Some((delay_seconds, code)), None, None),
    );
}

#[cfg(unix)]
fn fake_acp_agent_script(
    exit: Option<(f32, i32)>,
    prompt_delay: Option<f32>,
    cancel_log: Option<&Path>,
) -> String {
    let exit_setup = exit.map_or_else(String::new, |(delay, code)| {
        format!("threading.Timer({delay}, lambda: os._exit({code})).start()\n",)
    });
    let prompt_delay = prompt_delay.unwrap_or(0.0);
    let cancel_log = cancel_log
        .map(|path| format!("{:?}", path.display().to_string()))
        .unwrap_or_else(|| "None".to_string());
    format!(
        r#"#!/usr/bin/env python3
import json
import os
import sys
import threading
import time

{exit_setup}next_session = 1
prompt_delay = {prompt_delay}
cancel_log = {cancel_log}
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        result = {{"protocolVersion": message.get("params", {{}}).get("protocolVersion", 1),
                  "agentCapabilities": {{}}}}
    elif method == "session/new":
        result = {{"sessionId": f"acp-session-{{next_session}}"}}
        next_session += 1
    elif method == "session/prompt":
        if prompt_delay > 0:
            time.sleep(prompt_delay)
        result = {{"stopReason": "end_turn"}}
    elif method == "session/cancel":
        if cancel_log is not None:
            params = message.get("params", {{}})
            session_id = params.get("sessionId") or params.get("session_id") or message.get("sessionId") or ""
            with open(cancel_log, "a", encoding="utf-8") as handle:
                handle.write(session_id + "\n")
        continue
    else:
        result = {{}}
    if "id" in message:
        print(json.dumps({{"jsonrpc": "2.0", "id": message["id"], "result": result}}),
              flush=True)
"#
    )
}
