use std::env::current_dir;
use std::path::{Path, PathBuf};
use std::process::Command;

use fs_err as fs;
use serde::{Deserialize, Serialize};
use uzers::get_current_uid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;

use super::state;

pub const LAUNCH_AGENT_LABEL: &str = "io.harness.daemon";
const LEGACY_LAUNCH_AGENT_LABEL: &str = "io.harness.monitor.daemon";

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

/// Boot out the user `LaunchAgent` runtime if it is currently loaded.
///
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without touching `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, or when `launchctl bootout`
/// fails for a reason other than a missing service.
pub fn bootout_launch_agent(sandboxed: bool) -> Result<bool, CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-bootout",
        )));
    }
    best_effort_bootout(&run_launchctl)
}

/// Restart the installed user `LaunchAgent` without rewriting the plist.
///
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without touching `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, when the plist is missing,
/// or when `launchctl` operations fail.
pub fn restart_launch_agent(sandboxed: bool) -> Result<(), CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-restart",
        )));
    }
    restart_launch_agent_with(&run_launchctl)
}

/// Install the user `LaunchAgent` plist for the harness daemon.
///
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without writing the plist or calling `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, or on filesystem failures.
pub fn install_launch_agent(sandboxed: bool, binary_path: &Path) -> Result<PathBuf, CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-install",
        )));
    }
    install_launch_agent_with(binary_path, &run_launchctl)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn restart_launch_agent_with<F>(runner: &F) -> Result<(), CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    if !cfg!(target_os = "macos") {
        return Err(CliError::from(CliErrorKind::workflow_io(
            "launchd is only supported on macOS",
        )));
    }

    let path = state::launch_agent_path();
    if !path.is_file() {
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "launch agent plist not installed: {}",
            path.display()
        ))));
    }

    tracing::info!("launchd: bootout");
    best_effort_bootout(runner)?;
    tracing::info!("launchd: bootstrap");
    bootstrap_launch_agent(&path, runner)?;
    // RunAtLoad=true in the plist starts the daemon automatically after
    // bootstrap. kickstart -k is not needed and adds 10s blocking wait.
    tracing::info!("launchd: restart complete");
    Ok(())
}

fn install_launch_agent_with<F>(binary_path: &Path, runner: &F) -> Result<PathBuf, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    state::ensure_daemon_dirs()?;
    remove_legacy_launch_agent_with(runner)?;
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
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without touching the filesystem or `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, or on filesystem failures.
pub fn remove_launch_agent(sandboxed: bool) -> Result<bool, CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-remove",
        )));
    }
    remove_launch_agent_with(&run_launchctl)
}

fn remove_launch_agent_with<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let mut removed = remove_legacy_launch_agent_with(runner)?;
    let path = state::launch_agent_path();
    removed |= if cfg!(target_os = "macos") {
        best_effort_bootout(runner)?
    } else {
        false
    };
    if !path.exists() {
        return Ok(removed);
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
    let current_path = state::launch_agent_path();
    let mut status = launch_agent_status_template(LAUNCH_AGENT_LABEL, &current_path);
    if !cfg!(target_os = "macos") {
        status.status_error = Some("launchd is only supported on macOS".to_string());
        return status;
    }

    let current_status = inspect_launch_agent_status(LAUNCH_AGENT_LABEL, &current_path, runner);
    if current_status.loaded || current_status.installed || current_status.status_error.is_some() {
        return current_status;
    }

    let legacy_status = inspect_launch_agent_status(
        LEGACY_LAUNCH_AGENT_LABEL,
        &state::legacy_launch_agent_path(),
        runner,
    );
    if legacy_status.loaded || legacy_status.installed || legacy_status.status_error.is_some() {
        status.installed = legacy_status.installed;
        status.loaded = legacy_status.loaded;
        status.state = legacy_status.state;
        status.pid = legacy_status.pid;
        status.last_exit_status = legacy_status.last_exit_status;
        status.status_error = legacy_status.status_error;
    }

    status
}

fn launch_agent_status_template(label: &str, path: &Path) -> LaunchAgentStatus {
    let domain_target = launchd_domain_target();
    let service_target = launchd_service_target_for(label);
    LaunchAgentStatus {
        installed: path.is_file(),
        loaded: false,
        label: label.to_string(),
        path: path.display().to_string(),
        domain_target,
        service_target,
        state: None,
        pid: None,
        last_exit_status: None,
        status_error: None,
    }
}

fn inspect_launch_agent_status<F>(label: &str, path: &Path, runner: &F) -> LaunchAgentStatus
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let mut status = launch_agent_status_template(label, path);
    let args = vec!["print".to_string(), launchd_service_target_for(label)];
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
    let output = runner(&args)?;
    ensure_launchctl_success("bootstrap launch agent", &output)
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
    let output = runner(&args)?;
    ensure_launchctl_success("kickstart launch agent", &output)
}

fn remove_legacy_launch_agent_with<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let mut removed = if cfg!(target_os = "macos") {
        best_effort_bootout_for(LEGACY_LAUNCH_AGENT_LABEL, runner)?
    } else {
        false
    };

    let path = state::legacy_launch_agent_path();
    if !path.exists() {
        return Ok(removed);
    }

    fs::remove_file(path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "remove legacy launch agent plist: {error}"
        )))
    })?;
    removed = true;
    Ok(removed)
}

fn best_effort_bootout<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    best_effort_bootout_for(LAUNCH_AGENT_LABEL, runner)
}

fn best_effort_bootout_for<F>(label: &str, runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let args = vec!["bootout".to_string(), launchd_service_target_for(label)];
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

fn ensure_launchctl_success(action: &str, output: &CommandOutput) -> Result<(), CliError> {
    if output.exit_code == 0 {
        return Ok(());
    }
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "{action}: {}",
        command_message(output)
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
    launchd_service_target_for(LAUNCH_AGENT_LABEL)
}

fn launchd_service_target_for(label: &str) -> String {
    format!("{}/{}", launchd_domain_target(), label)
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
    fn install_launch_agent_removes_legacy_plist() {
        let tmp = tempdir().expect("tempdir");
        let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
        let runner = {
            let calls = Arc::clone(&calls);
            move |args: &[String]| -> Result<CommandOutput, CliError> {
                calls.lock().expect("lock").push(args.to_vec());
                Ok(CommandOutput {
                    exit_code: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
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
                let legacy_path = state::legacy_launch_agent_path();
                fs::create_dir_all(legacy_path.parent().expect("legacy parent"))
                    .expect("create legacy launch agent dir");
                fs::write(&legacy_path, "legacy plist").expect("write legacy plist");

                let path = install_launch_agent_with(Path::new("/tmp/harness-bin"), &runner)
                    .expect("install launch agent");

                assert!(path.is_file());
                assert!(!legacy_path.exists());
                assert!(calls.lock().expect("lock").iter().any(|args| {
                    args == &vec![
                        "bootout".to_string(),
                        launchd_service_target_for(LEGACY_LAUNCH_AGENT_LABEL),
                    ]
                }));
            },
        );
    }

    #[test]
    fn restart_launch_agent_uses_existing_plist() {
        let tmp = tempdir().expect("tempdir");
        let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
        let runner = {
            let calls = Arc::clone(&calls);
            move |args: &[String]| -> Result<CommandOutput, CliError> {
                calls.lock().expect("lock").push(args.to_vec());
                Ok(CommandOutput {
                    exit_code: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
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
                let path = state::launch_agent_path();
                fs::create_dir_all(path.parent().expect("launch agent dir"))
                    .expect("create launch agent dir");
                fs::write(&path, "plist").expect("write plist");

                restart_launch_agent_with(&runner).expect("restart launch agent");

                let calls = calls.lock().expect("lock");
                assert_eq!(
                    calls[0],
                    vec!["bootout".to_string(), launchd_service_target()]
                );
                assert_eq!(
                    calls[1],
                    vec![
                        "bootstrap".to_string(),
                        launchd_domain_target(),
                        path.display().to_string(),
                    ]
                );
                assert_eq!(calls.len(), 2, "bootout + bootstrap only, no kickstart");
            },
        );
    }

    #[test]
    fn best_effort_bootout_returns_true_on_success() {
        let calls = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
        let runner = {
            let calls = Arc::clone(&calls);
            move |args: &[String]| -> Result<CommandOutput, CliError> {
                calls.lock().expect("lock").push(args.to_vec());
                Ok(CommandOutput {
                    exit_code: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
            }
        };

        let booted_out = best_effort_bootout(&runner).expect("bootout launch agent");

        assert!(booted_out);
        assert_eq!(
            calls.lock().expect("lock").as_slice(),
            &[vec!["bootout".to_string(), launchd_service_target()]]
        );
    }

    #[test]
    fn best_effort_bootout_returns_false_when_service_is_missing() {
        let booted_out = best_effort_bootout(&|args| {
            assert_eq!(args, &["bootout".to_string(), launchd_service_target()]);
            Ok(CommandOutput {
                exit_code: 1,
                stdout: String::new(),
                stderr: "Could not find service".to_string(),
            })
        })
        .expect("bootout should treat a missing service as success");

        assert!(!booted_out);
    }

    #[test]
    fn restart_launch_agent_requires_installed_plist() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                let error = restart_launch_agent_with(&|_args| {
                    panic!("runner should not be called when plist is missing");
                })
                .expect_err("restart should fail without a plist");
                assert!(
                    error
                        .to_string()
                        .contains("launch agent plist not installed")
                );
            },
        );
    }

    #[test]
    fn parse_launchctl_print_extracts_runtime_fields() {
        let parsed = parse_launchctl_print(
            r#"gui/501/io.harness.daemon = {
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
                stderr: "Could not find service \"io.harness.daemon\"".to_string(),
            })
        });
        assert!(!status.loaded);
        assert!(status.status_error.is_none());
    }

    #[test]
    fn launch_agent_status_coalesces_legacy_runtime_into_current_contract() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                let legacy_path = state::legacy_launch_agent_path();
                fs::create_dir_all(legacy_path.parent().expect("legacy parent"))
                    .expect("create legacy launch agent dir");
                fs::write(&legacy_path, "legacy plist").expect("write legacy plist");

                let status = launch_agent_status_with(&|args| {
                    assert_eq!(args.first().map(String::as_str), Some("print"));

                    if args
                        .get(1)
                        .is_some_and(|value| value == &launchd_service_target())
                    {
                        return Ok(CommandOutput {
                            exit_code: 1,
                            stdout: String::new(),
                            stderr: "Could not find service".to_string(),
                        });
                    }

                    assert_eq!(
                        args.get(1),
                        Some(&launchd_service_target_for(LEGACY_LAUNCH_AGENT_LABEL))
                    );
                    Ok(CommandOutput {
                        exit_code: 0,
                        stdout: format!(
                            r#"{service} = {{
    state = running
    pid = 4242
    last exit code = 0
}}"#,
                            service = launchd_service_target_for(LEGACY_LAUNCH_AGENT_LABEL)
                        ),
                        stderr: String::new(),
                    })
                });

                assert!(status.installed);
                assert!(status.loaded);
                assert_eq!(status.label, LAUNCH_AGENT_LABEL);
                assert_eq!(
                    status.path,
                    state::launch_agent_path().display().to_string()
                );
                assert_eq!(status.service_target, launchd_service_target());
                assert_eq!(status.state.as_deref(), Some("running"));
                assert_eq!(status.pid, Some(4242));
                assert_eq!(status.last_exit_status, Some(0));
            },
        );
    }

    #[test]
    fn bootout_launch_agent_refuses_in_sandbox_mode() {
        let error = bootout_launch_agent(true).expect_err("sandbox mode must refuse bootout");
        assert_eq!(error.code(), "SANDBOX001");
        assert!(error.to_string().contains("launch-agent-bootout"));
    }

    #[test]
    fn restart_launch_agent_refuses_in_sandbox_mode() {
        let error = restart_launch_agent(true).expect_err("sandbox mode must refuse restart");
        assert_eq!(error.code(), "SANDBOX001");
        assert!(error.to_string().contains("launch-agent-restart"));
    }

    #[test]
    fn install_launch_agent_refuses_in_sandbox_mode() {
        let error = install_launch_agent(true, Path::new("/tmp/harness-bin"))
            .expect_err("sandbox mode must refuse install");
        assert_eq!(error.code(), "SANDBOX001");
        assert!(error.to_string().contains("launch-agent-install"));
    }

    #[test]
    fn remove_launch_agent_refuses_in_sandbox_mode() {
        let error = remove_launch_agent(true).expect_err("sandbox mode must refuse remove");
        assert_eq!(error.code(), "SANDBOX001");
        assert!(error.to_string().contains("launch-agent-remove"));
    }
}
