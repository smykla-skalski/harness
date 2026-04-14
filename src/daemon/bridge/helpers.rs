use std::collections::BTreeMap;
use std::env::{split_paths, var, var_os};
use std::fs::Metadata;
use std::io::ErrorKind;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use chrono::{DateTime, Utc};
use fs_err as fs;
use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;

use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};

use super::bridge_state::bridge_socket_path;
use super::core::ResolvedBridgeConfig;
use super::types::{
    BRIDGE_LAUNCH_AGENT_LABEL, BridgeCapability, BridgeConfigArgs, BridgeStatusReport,
    DEFAULT_CODEX_BRIDGE_PORT, PersistedBridgeConfig, compiled_capabilities,
};

pub(super) fn parse_bridge_payload<T: DeserializeOwned>(payload: Value) -> Result<T, CliError> {
    serde_json::from_value(payload).map_err(|error| {
        CliErrorKind::workflow_parse(format!("decode bridge payload: {error}")).into()
    })
}

pub(super) fn stringify_metadata_map<T: Serialize>(value: &T) -> BTreeMap<String, String> {
    let Ok(Value::Object(entries)) = serde_json::to_value(value) else {
        return BTreeMap::new();
    };
    entries
        .into_iter()
        .filter_map(|(key, value)| {
            let value = match value {
                Value::Null => return None,
                Value::String(value) => value,
                other => other.to_string(),
            };
            Some((key, value))
        })
        .collect()
}

pub(super) fn print_json(report: &BridgeStatusReport) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(report)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}

pub(super) fn print_status_plain(report: &BridgeStatusReport) {
    if report.running {
        let socket = report.socket_path.as_deref().unwrap_or("?");
        let pid = report
            .pid
            .map_or_else(|| "?".to_string(), |pid| pid.to_string());
        let capabilities = report
            .capabilities
            .keys()
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        println!("running at {socket} (pid {pid}; capabilities: {capabilities})");
    } else {
        println!("not running");
    }
}

pub(super) fn remove_if_exists(path: &Path) -> Result<(), CliError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => {
            Err(CliErrorKind::workflow_io(format!("remove {}: {error}", path.display())).into())
        }
    }
}

fn remove_owned_legacy_socket_if_exists(socket_path: &Path) -> Result<(), CliError> {
    let Some(canonical_socket_path) = legacy_socket_cleanup_target(socket_path)? else {
        return Ok(());
    };
    remove_if_exists(&canonical_socket_path)
}

fn canonicalize_existing_path(path: &Path) -> Result<Option<PathBuf>, CliError> {
    match fs::canonicalize(path) {
        Ok(canonical_path) => Ok(Some(canonical_path)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(CliErrorKind::workflow_io(format!(
            "canonicalize {}: {error}",
            path.display()
        ))
        .into()),
    }
}

fn legacy_socket_cleanup_target(socket_path: &Path) -> Result<Option<PathBuf>, CliError> {
    let Some(canonical_socket_path) = canonicalize_existing_path(socket_path)? else {
        return Ok(None);
    };
    if !path_is_under_daemon_root(&canonical_socket_path)? {
        return Ok(None);
    }
    if !path_is_socket(&canonical_socket_path)? {
        return Ok(None);
    }
    Ok(Some(canonical_socket_path))
}

fn path_is_under_daemon_root(path: &Path) -> Result<bool, CliError> {
    let Some(canonical_root) = canonicalize_existing_path(&state::daemon_root())? else {
        return Ok(false);
    };
    Ok(report_root_membership(path, &canonical_root))
}

fn path_is_socket(path: &Path) -> Result<bool, CliError> {
    let is_socket = read_path_metadata(path)?.file_type().is_socket();
    Ok(report_socket_kind(path, is_socket))
}

fn read_path_metadata(path: &Path) -> Result<Metadata, CliError> {
    fs::metadata(path).map_err(|error| {
        CliErrorKind::workflow_io(format!("read metadata for {}: {error}", path.display())).into()
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn report_root_membership(path: &Path, root: &Path) -> bool {
    let is_under_root = path.starts_with(root);
    if !is_under_root {
        tracing::warn!(
            path = %path.display(),
            root = %root.display(),
            "skipping legacy bridge cleanup outside daemon root"
        );
    }
    is_under_root
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn report_socket_kind(path: &Path, is_socket: bool) -> bool {
    if !is_socket {
        tracing::warn!(
            path = %path.display(),
            "skipping legacy bridge cleanup for non-socket path"
        );
    }
    is_socket
}

fn resolve_codex_binary(explicit: Option<&Path>) -> Result<PathBuf, CliError> {
    if let Some(path) = explicit {
        if path.is_file() {
            return Ok(path.to_path_buf());
        }
        return Err(CliErrorKind::workflow_io(format!(
            "codex binary not found at {}",
            path.display()
        ))
        .into());
    }
    if let Some(path) = find_on_path("codex") {
        return Ok(path);
    }
    Err(CliErrorKind::workflow_io(
        "codex binary not found on PATH; use --codex-path to specify it".to_string(),
    )
    .into())
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path_var = var_os("PATH")?;
    for directory in split_paths(&path_var) {
        let candidate = directory.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

pub(super) fn detect_codex_version(binary: &Path) -> Option<String> {
    let output = Command::new(binary)
        .arg("--version")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.to_string())
}

pub(super) fn uptime_from_started_at(started_at: &str) -> Option<u64> {
    let started: DateTime<Utc> = DateTime::parse_from_rfc3339(started_at).ok()?.into();
    let duration = Utc::now().signed_duration_since(started);
    u64::try_from(duration.num_seconds()).ok()
}

pub(super) fn launch_agent_plist_path() -> Result<PathBuf, CliError> {
    let home = var("HOME").map_err(|_| {
        CliErrorKind::workflow_io("HOME is not set; cannot determine LaunchAgent path")
    })?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{BRIDGE_LAUNCH_AGENT_LABEL}.plist")))
}

pub(super) fn render_launch_agent_plist(harness_binary: &Path) -> String {
    let args = [
        format!("<string>{}</string>", harness_binary.display()),
        "<string>bridge</string>".to_string(),
        "<string>start</string>".to_string(),
    ];
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    {arguments}
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HARNESS_APP_GROUP_ID</key>
    <string>Q498EB36N4.io.harnessmonitor</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        label = BRIDGE_LAUNCH_AGENT_LABEL,
        arguments = args.join("\n    "),
        stdout = state::daemon_root().join("bridge.stdout.log").display(),
        stderr = state::daemon_root().join("bridge.stderr.log").display(),
    )
}

pub(super) fn merged_persisted_config(
    explicit: &BridgeConfigArgs,
    persisted: Option<PersistedBridgeConfig>,
) -> PersistedBridgeConfig {
    let persisted = persisted.unwrap_or_else(|| PersistedBridgeConfig {
        capabilities: compiled_capabilities().into_iter().collect(),
        ..PersistedBridgeConfig::default()
    });
    PersistedBridgeConfig {
        capabilities: if explicit.capabilities.is_empty() {
            persisted.capabilities
        } else {
            explicit.capabilities.clone()
        },
        socket_path: explicit.socket_path.clone().or(persisted.socket_path),
        codex_port: explicit.codex_port.or(persisted.codex_port),
        codex_path: explicit.codex_path.clone().or(persisted.codex_path),
    }
    .normalized()
}

pub(super) fn resolve_bridge_config(
    config: PersistedBridgeConfig,
) -> Result<ResolvedBridgeConfig, CliError> {
    let persisted = config.normalized();
    let capabilities = persisted.capabilities_set();
    let socket_path = persisted
        .socket_path
        .clone()
        .unwrap_or_else(bridge_socket_path);
    let codex_port = persisted.codex_port.unwrap_or(DEFAULT_CODEX_BRIDGE_PORT);
    let codex_binary = if capabilities.contains(&BridgeCapability::Codex) {
        Some(resolve_codex_binary(persisted.codex_path.as_deref())?)
    } else {
        None
    };
    Ok(ResolvedBridgeConfig {
        persisted,
        capabilities,
        socket_path,
        codex_port,
        codex_binary,
    })
}

pub(super) fn best_effort_bootout(label: &str) {
    if !cfg!(target_os = "macos") {
        return;
    }
    let target = format!("gui/{}/{}", uzers::get_current_uid(), label);
    let _ = Command::new("launchctl")
        .args(["bootout", &target])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

pub(super) fn bootstrap_agent(plist_path: &Path) -> Result<(), CliError> {
    let domain = format!("gui/{}", uzers::get_current_uid());
    let output = Command::new("launchctl")
        .args(["bootstrap", &domain, &plist_path.display().to_string()])
        .output()
        .map_err(|error| CliErrorKind::workflow_io(format!("run launchctl bootstrap: {error}")))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.to_ascii_lowercase().contains("already loaded")
        || stderr.to_ascii_lowercase().contains("already bootstrapped")
    {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!("launchctl bootstrap failed: {stderr}")).into())
}

pub(super) fn cleanup_legacy_bridge_artifacts() {
    if cfg!(target_os = "macos") {
        best_effort_bootout("io.harness.codex-bridge");
        best_effort_bootout("io.harness.agent-tui-bridge");
    }
    let _ = remove_if_exists(&state::daemon_root().join("codex-endpoint.json"));
    let _ = remove_if_exists(&state::daemon_root().join("codex-bridge.pid"));
    let _ = remove_if_exists(&state::daemon_root().join("codex-bridge.stdout.log"));
    let _ = remove_if_exists(&state::daemon_root().join("codex-bridge.stderr.log"));
    let _ = remove_if_exists(&state::daemon_root().join("agent-tui-bridge.stdout.log"));
    let _ = remove_if_exists(&state::daemon_root().join("agent-tui-bridge.stderr.log"));
    let legacy_agent_tui_state = state::daemon_root().join("agent-tui-bridge.json");
    if let Ok(data) = fs::read_to_string(&legacy_agent_tui_state)
        && let Ok(value) = serde_json::from_str::<Value>(&data)
        && let Some(socket_path) = value.get("socket_path").and_then(Value::as_str)
    {
        let _ = remove_owned_legacy_socket_if_exists(Path::new(socket_path));
    }
    let _ = remove_if_exists(&legacy_agent_tui_state);
    let _ = remove_if_exists(&state::daemon_root().join("agent-tui-bridge.sock"));
    if let Ok(home) = var("HOME") {
        let launch_agents = PathBuf::from(home).join("Library").join("LaunchAgents");
        let _ = remove_if_exists(&launch_agents.join("io.harness.codex-bridge.plist"));
        let _ = remove_if_exists(&launch_agents.join("io.harness.agent-tui-bridge.plist"));
    }
}
