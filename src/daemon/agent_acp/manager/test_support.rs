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
    write_executable(path, &fake_acp_agent_script(None, None));
}

#[cfg(unix)]
pub(super) fn write_prompt_delaying_acp_agent(path: &Path, delay_seconds: f32) {
    write_executable(path, &fake_acp_agent_script(None, Some(delay_seconds)));
}

#[cfg(unix)]
pub(super) fn write_exiting_acp_agent(path: &Path, delay_seconds: f32, code: i32) {
    write_executable(
        path,
        &fake_acp_agent_script(Some((delay_seconds, code)), None),
    );
}

#[cfg(unix)]
fn fake_acp_agent_script(exit: Option<(f32, i32)>, prompt_delay: Option<f32>) -> String {
    let exit_setup = exit.map_or_else(String::new, |(delay, code)| {
        format!("threading.Timer({delay}, lambda: os._exit({code})).start()\n",)
    });
    let prompt_delay = prompt_delay.unwrap_or(0.0);
    format!(
        r#"#!/usr/bin/env python3
import json
import os
import sys
import threading
import time

{exit_setup}next_session = 1
prompt_delay = {prompt_delay}
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
        continue
    else:
        result = {{}}
    if "id" in message:
        print(json.dumps({{"jsonrpc": "2.0", "id": message["id"], "result": result}}),
              flush=True)
"#
    )
}
