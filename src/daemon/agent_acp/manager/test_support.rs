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
    write_executable(path, &fake_acp_agent_script(None));
}

#[cfg(unix)]
pub(super) fn write_exiting_acp_agent(path: &Path, delay_seconds: f32, code: i32) {
    write_executable(path, &fake_acp_agent_script(Some((delay_seconds, code))));
}

#[cfg(unix)]
fn fake_acp_agent_script(exit: Option<(f32, i32)>) -> String {
    let exit_setup = exit.map_or_else(String::new, |(delay, code)| {
        format!("threading.Timer({delay}, lambda: os._exit({code})).start()\n",)
    });
    format!(
        r#"#!/usr/bin/env python3
import json
import os
import sys
import threading

{exit_setup}next_session = 1
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        result = {{"protocolVersion": message.get("params", {{}}).get("protocolVersion", 1),
                  "agentCapabilities": {{}}}}
    elif method == "session/new":
        result = {{"sessionId": f"acp-session-{{next_session}}"}}
        next_session += 1
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
