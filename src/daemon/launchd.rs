use std::env::current_dir;
use std::path::{Path, PathBuf};
use std::process::Command;

use fs_err as fs;
use serde::{Deserialize, Serialize};
use uzers::get_current_uid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;

use super::state;

pub const LAUNCH_AGENT_LABEL: &str = "io.harness.monitor.daemon";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaunchAgentStatus {
    pub installed: bool,
    pub loaded: bool,
    pub label: String,
    pub path: String,
    pub domain_target: String,
    pub service_target: String,
    pub state: Option<String>,
    pub pid: Option<i32>,
    pub last_exit_status: Option<i32>,
    pub status_error: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct LaunchctlPrintStatus {
    state: Option<String>,
    pid: Option<i32>,
    last_exit_status: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommandOutput {
    exit_code: i32,
    stdout: String,
    stderr: String,
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
    install_launch_agent_with(binary_path, &run_launchctl)
}

fn install_launch_agent_with<F>(binary_path: &Path, runner: &F) -> Result<PathBuf, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
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
    if cfg!(target_os = "macos") {
        best_effort_bootout(runner)?;
        bootstrap_launch_agent(&path, runner)?;
        kickstart_launch_agent(runner)?;
    }
    Ok(path)
}

/// Remove the user `LaunchAgent` plist if present.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn remove_launch_agent() -> Result<bool, CliError> {
    remove_launch_agent_with(&run_launchctl)
}

fn remove_launch_agent_with<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let path = state::launch_agent_path();
    let had_plist = path.exists();
    let unloaded = if cfg!(target_os = "macos") {
        best_effort_bootout(runner)?
    } else {
        false
    };
    if !had_plist {
        return Ok(unloaded);
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
    launch_agent_status_with(&run_launchctl)
}

fn launch_agent_status_with<F>(runner: &F) -> LaunchAgentStatus
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let path = state::launch_agent_path();
    let domain_target = launchd_domain_target();
    let service_target = launchd_service_target();
    let mut status = LaunchAgentStatus {
        installed: path.is_file(),
        loaded: false,
        label: LAUNCH_AGENT_LABEL.to_string(),
        path: path.display().to_string(),
        domain_target,
        service_target: service_target.clone(),
        state: None,
        pid: None,
        last_exit_status: None,
        status_error: None,
    };
    if !cfg!(target_os = "macos") {
        status.status_error = Some("launchd is only supported on macOS".to_string());
        return status;
    }
    let args = vec!["print".to_string(), service_target];
    match runner(&args) {
        Ok(output) => apply_launchctl_status(&mut status, &output),
        Err(error) => {
            status.status_error = Some(error.to_string());
        }
    }
    status
}

fn apply_launchctl_status(status: &mut LaunchAgentStatus, output: &CommandOutput) {
    if output.exit_code == 0 {
        let parsed = parse_launchctl_print(&output.stdout);
        status.loaded = true;
        status.state = parsed.state;
        status.pid = parsed.pid;
        status.last_exit_status = parsed.last_exit_status;
        return;
    }
    let combined = command_message(output);
    if launchctl_reports_missing_service(&combined) {
        return;
    }
    status.status_error = Some(combined);
}

fn parse_launchctl_print(output: &str) -> LaunchctlPrintStatus {
    let mut status = LaunchctlPrintStatus::default();
    for line in output.lines().map(str::trim) {
        if let Some(value) = line.strip_prefix("state = ") {
            status.state = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("pid = ") {
            status.pid = value.parse::<i32>().ok();
        } else if let Some(value) = line.strip_prefix("last exit code = ") {
            status.last_exit_status = value.parse::<i32>().ok();
        }
    }
    status
}

fn bootstrap_launch_agent<F>(path: &Path, runner: &F) -> Result<(), CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let args = vec![
        "bootstrap".to_string(),
        launchd_domain_target(),
        path.display().to_string(),
    ];
    ensure_launchctl_success("bootstrap launch agent", runner(&args)?)
}

fn kickstart_launch_agent<F>(runner: &F) -> Result<(), CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let args = vec![
        "kickstart".to_string(),
        "-k".to_string(),
        launchd_service_target(),
    ];
    ensure_launchctl_success("kickstart launch agent", runner(&args)?)
}

fn best_effort_bootout<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let args = vec!["bootout".to_string(), launchd_service_target()];
    let output = runner(&args)?;
    if output.exit_code == 0 {
        return Ok(true);
    }
    let message = command_message(&output);
    if launchctl_reports_missing_service(&message) {
        return Ok(false);
    }
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "bootout launch agent: {message}"
    ))))
}

fn ensure_launchctl_success(action: &str, output: CommandOutput) -> Result<(), CliError> {
    if output.exit_code == 0 {
        return Ok(());
    }
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "{action}: {}",
        command_message(&output)
    ))))
}

fn run_launchctl(args: &[String]) -> Result<CommandOutput, CliError> {
    let output = Command::new("launchctl")
        .args(args)
        .output()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "run launchctl {}: {error}",
                args.join(" ")
            )))
        })?;
    Ok(CommandOutput {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

fn command_message(output: &CommandOutput) -> String {
    let stderr = output.stderr.trim();
    if !stderr.is_empty() {
        return stderr.to_string();
    }
    let stdout = output.stdout.trim();
    if !stdout.is_empty() {
        return stdout.to_string();
    }
    format!("launchctl exited with status {}", output.exit_code)
}

fn launchctl_reports_missing_service(message: &str) -> bool {
    let lowercase = message.to_ascii_lowercase();
    lowercase.contains("could not find service")
        || lowercase.contains("service could not be found")
        || lowercase.contains("no such process")
        || lowercase.contains("not loaded")
}

fn launchd_domain_target() -> String {
    format!("gui/{}", get_current_uid())
}

fn launchd_service_target() -> String {
    format!("{}/{}", launchd_domain_target(), LAUNCH_AGENT_LABEL)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    use tempfile::tempdir;

    #[test]
    fn render_launch_agent_plist_contains_expected_fields() {
        let plist = render_launch_agent_plist(Path::new("/usr/local/bin/harness"));
        assert!(plist.contains(LAUNCH_AGENT_LABEL));
        assert!(plist.contains("<string>daemon</string>"));
        assert!(plist.contains("<string>serve</string>"));
    }

    #[test]
    fn launch_agent_install_and_remove_round_trip() {
        let tmp = tempdir().expect("tempdir");
        let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
        let runner = {
            let calls = Arc::clone(&calls);
            move |args: &[String]| -> Result<CommandOutput, CliError> {
                calls.lock().expect("lock").push(args.to_vec());
                let output = if args.first().is_some_and(|value| value == "print") {
                    CommandOutput {
                        exit_code: 1,
                        stdout: String::new(),
                        stderr: "Could not find service".to_string(),
                    }
                } else {
                    CommandOutput {
                        exit_code: 0,
                        stdout: String::new(),
                        stderr: String::new(),
                    }
                };
                Ok(output)
            }
        };
        temp_env::with_vars(
            [
                ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                let path = install_launch_agent_with(Path::new("/tmp/harness-bin"), &runner)
                    .expect("install launch agent");
                assert_eq!(path, state::launch_agent_path());
                assert!(path.is_file());

                let status = launch_agent_status_with(&|args| {
                    if args.first().is_some_and(|value| value == "print") {
                        return Ok(CommandOutput {
                            exit_code: 0,
                            stdout: format!(
                                r#"{service} = {{
    state = running
    pid = 4242
    last exit code = 0
}}"#,
                                service = launchd_service_target()
                            ),
                            stderr: String::new(),
                        });
                    }
                    runner(args)
                });
                assert!(status.installed);
                assert!(status.loaded);
                assert_eq!(status.label, LAUNCH_AGENT_LABEL);
                assert_eq!(status.state.as_deref(), Some("running"));
                assert_eq!(status.pid, Some(4242));
                assert_eq!(status.last_exit_status, Some(0));

                let plist = fs::read_to_string(&path).expect("read plist");
                assert!(plist.contains("/tmp/harness-bin"));
                assert!(plist.contains("daemon"));
                assert!(plist.contains("serve"));

                assert!(remove_launch_agent_with(&runner).expect("remove launch agent"));
                assert!(!path.exists());
                assert!(
                    calls
                        .lock()
                        .expect("lock")
                        .iter()
                        .any(|args| { args.first().is_some_and(|value| value == "bootstrap") })
                );
                assert!(
                    calls
                        .lock()
                        .expect("lock")
                        .iter()
                        .any(|args| { args.first().is_some_and(|value| value == "kickstart") })
                );
            },
        );
    }

    #[test]
    fn parse_launchctl_print_extracts_runtime_fields() {
        let parsed = parse_launchctl_print(
            r#"gui/501/io.harness.monitor.daemon = {
    state = waiting
    pid = 98321
    last exit code = 78
}"#,
        );
        assert_eq!(
            parsed,
            LaunchctlPrintStatus {
                state: Some("waiting".to_string()),
                pid: Some(98_321),
                last_exit_status: Some(78),
            }
        );
    }

    #[test]
    fn launch_agent_status_marks_missing_service_as_not_loaded() {
        let status = launch_agent_status_with(&|args| {
            assert_eq!(args.first().map(String::as_str), Some("print"));
            Ok(CommandOutput {
                exit_code: 1,
                stdout: String::new(),
                stderr: "Could not find service \"io.harness.monitor.daemon\"".to_string(),
            })
        });
        assert!(!status.loaded);
        assert!(status.status_error.is_none());
    }
}
