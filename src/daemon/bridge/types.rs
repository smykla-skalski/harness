use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::time::Duration;

use clap::{Args, ValueEnum};
use serde::{Deserialize, Serialize};

use crate::daemon::agent_tui::{AgentTuiLaunchProfile, AgentTuiSize};
use crate::daemon::state::HostBridgeCapabilityManifest;
use crate::errors::CliError;

use super::bridge_state::read_bridge_config;
use super::core::ResolvedBridgeConfig;
use super::helpers::{merged_persisted_config, resolve_bridge_config, uptime_from_started_at};

pub const BRIDGE_LAUNCH_AGENT_LABEL: &str = "io.harness.bridge";
pub const BRIDGE_CAPABILITY_CODEX: &str = "codex";
pub const BRIDGE_CAPABILITY_AGENT_TUI: &str = "agent-tui";
pub const DEFAULT_CODEX_BRIDGE_PORT: u16 = 4500;
pub const CODEX_BRIDGE_PORT_ENV: &str = "HARNESS_CODEX_WS_PORT";

pub(super) const STOP_GRACE_PERIOD: Duration = Duration::from_secs(5);
pub(super) const STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);
pub(super) const DETACHED_START_TIMEOUT: Duration = Duration::from_secs(12);
pub(super) const DETACHED_START_POLL_INTERVAL: Duration = Duration::from_millis(50);
pub(super) const WATCH_DEBOUNCE: Duration = Duration::from_millis(200);
pub(super) const CODEX_READY_TIMEOUT: Duration = Duration::from_secs(10);
pub(super) const CODEX_READY_POLL_INTERVAL: Duration = Duration::from_millis(100);
pub(super) const CODEX_READY_WARN_AFTER: Duration = Duration::from_secs(1);
pub(super) const CODEX_READY_PROBE_TIMEOUT: Duration = Duration::from_millis(500);
pub(super) const DEFAULT_BRIDGE_SOCKET_NAME: &str = "bridge.sock";
pub(super) const FALLBACK_BRIDGE_SOCKET_PREFIX: &str = "h-bridge-";
pub(super) const FALLBACK_BRIDGE_SOCKET_SUFFIX: &str = ".sock";
pub(super) const UNIX_SOCKET_PATH_LIMIT: usize = if cfg!(target_os = "macos") { 103 } else { 107 };

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum BridgeCapability {
    Codex,
    #[serde(rename = "agent-tui")]
    #[value(name = "agent-tui")]
    AgentTui,
}

impl BridgeCapability {
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Codex => BRIDGE_CAPABILITY_CODEX,
            Self::AgentTui => BRIDGE_CAPABILITY_AGENT_TUI,
        }
    }

    #[must_use]
    pub const fn sandbox_feature(self) -> &'static str {
        match self {
            Self::Codex => "codex.host-bridge",
            Self::AgentTui => "agent-tui.host-bridge",
        }
    }

    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            BRIDGE_CAPABILITY_CODEX => Some(Self::Codex),
            BRIDGE_CAPABILITY_AGENT_TUI => Some(Self::AgentTui),
            _ => None,
        }
    }
}

#[must_use]
pub fn compiled_capabilities() -> BTreeSet<BridgeCapability> {
    [BridgeCapability::Codex, BridgeCapability::AgentTui]
        .into_iter()
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeState {
    pub socket_path: String,
    pub pid: u32,
    pub started_at: String,
    pub token_path: String,
    #[serde(default)]
    pub capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeStatusReport {
    pub running: bool,
    pub socket_path: Option<String>,
    pub pid: Option<u32>,
    pub started_at: Option<String>,
    pub uptime_seconds: Option<u64>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
}

impl BridgeStatusReport {
    #[must_use]
    pub fn not_running() -> Self {
        Self {
            running: false,
            socket_path: None,
            pid: None,
            started_at: None,
            uptime_seconds: None,
            capabilities: BTreeMap::new(),
        }
    }
}

#[must_use]
pub(super) fn status_report_from_state(state: &BridgeState) -> BridgeStatusReport {
    BridgeStatusReport {
        running: true,
        socket_path: Some(state.socket_path.clone()),
        pid: Some(state.pid),
        started_at: Some(state.started_at.clone()),
        uptime_seconds: uptime_from_started_at(&state.started_at),
        capabilities: state.capabilities.clone(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub(super) struct PersistedBridgeConfig {
    #[serde(default)]
    pub(super) capabilities: Vec<BridgeCapability>,
    #[serde(default)]
    pub(super) socket_path: Option<PathBuf>,
    #[serde(default)]
    pub(super) codex_port: Option<u16>,
    #[serde(default)]
    pub(super) codex_path: Option<PathBuf>,
}

impl PersistedBridgeConfig {
    #[must_use]
    pub(super) fn normalized(mut self) -> Self {
        self.capabilities.sort();
        self.capabilities.dedup();
        self
    }

    #[must_use]
    pub(super) fn capabilities_set(&self) -> BTreeSet<BridgeCapability> {
        self.capabilities.iter().copied().collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiStartSpec {
    pub session_id: String,
    pub agent_id: String,
    pub tui_id: String,
    pub profile: AgentTuiLaunchProfile,
    pub project_dir: PathBuf,
    pub transcript_path: PathBuf,
    pub size: AgentTuiSize,
    pub prompt: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeConfigArgs {
    /// Explicit capability list. Omit the flag to enable every compiled capability.
    #[arg(long = "capability")]
    pub capabilities: Vec<BridgeCapability>,
    /// Override the control socket path.
    #[arg(long, value_name = "PATH")]
    pub socket_path: Option<PathBuf>,
    /// Port for the codex WebSocket capability.
    #[arg(long, env = CODEX_BRIDGE_PORT_ENV)]
    pub codex_port: Option<u16>,
    /// Explicit path to the `codex` binary.
    #[arg(long, value_name = "PATH")]
    pub codex_path: Option<PathBuf>,
}

impl BridgeConfigArgs {
    pub(super) fn resolve(&self) -> Result<ResolvedBridgeConfig, CliError> {
        let persisted = read_bridge_config()?;
        resolve_bridge_config(merged_persisted_config(self, persisted))
    }
}

#[derive(Debug, Clone, Args)]
pub struct BridgeStartArgs {
    #[command(flatten)]
    pub config: BridgeConfigArgs,
    /// Detach from the terminal and run in the background.
    #[arg(long)]
    pub daemon: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeStopArgs {
    /// Print the final status as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeStatusArgs {
    /// Print a one-line summary instead of JSON.
    #[arg(long)]
    pub plain: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeInstallLaunchAgentArgs {
    #[command(flatten)]
    pub config: BridgeConfigArgs,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeReconfigureArgs {
    /// Enable one capability without restarting the bridge.
    #[arg(long = "enable")]
    pub enable: Vec<BridgeCapability>,
    /// Disable one capability without restarting the bridge.
    #[arg(long = "disable")]
    pub disable: Vec<BridgeCapability>,
    /// Force-disable `agent-tui` by stopping active TUI sessions first.
    #[arg(long)]
    pub force: bool,
    /// Print the updated bridge status as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct BridgeRemoveLaunchAgentArgs {
    /// Print confirmation as JSON.
    #[arg(long)]
    pub json: bool,
}
