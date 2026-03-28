use std::env::current_dir;
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;

use super::state;

pub const LAUNCH_AGENT_LABEL: &str = "io.harness.monitor.daemon";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaunchAgentStatus {
    pub installed: bool,
    pub label: String,
    pub path: String,
}

#[must_use]
pub fn render_launch_agent_plist(binary_path: &Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{binary}</string>
    <string>daemon</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>{cwd}</string>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        label = LAUNCH_AGENT_LABEL,
        binary = binary_path.display(),
        cwd = current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .display(),
        stdout = state::daemon_root().join("launchd.stdout.log").display(),
        stderr = state::daemon_root().join("launchd.stderr.log").display(),
    )
}

/// Install the user `LaunchAgent` plist for the harness daemon.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn install_launch_agent(binary_path: &Path) -> Result<PathBuf, CliError> {
    state::ensure_daemon_dirs()?;
    let path = state::launch_agent_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "create launch agent dir: {error}"
            )))
        })?;
    }
    write_text(&path, &render_launch_agent_plist(binary_path))?;
    Ok(path)
}

/// Remove the user `LaunchAgent` plist if present.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn remove_launch_agent() -> Result<bool, CliError> {
    let path = state::launch_agent_path();
    if !path.exists() {
        return Ok(false);
    }
    fs::remove_file(path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "remove launch agent plist: {error}"
        )))
    })?;
    Ok(true)
}

#[must_use]
pub fn launch_agent_status() -> LaunchAgentStatus {
    let path = state::launch_agent_path();
    LaunchAgentStatus {
        installed: path.is_file(),
        label: LAUNCH_AGENT_LABEL.to_string(),
        path: path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_launch_agent_plist_contains_expected_fields() {
        let plist = render_launch_agent_plist(Path::new("/usr/local/bin/harness"));
        assert!(plist.contains(LAUNCH_AGENT_LABEL));
        assert!(plist.contains("<string>daemon</string>"));
        assert!(plist.contains("<string>serve</string>"));
    }
}
