#![expect(
    clippy::module_name_repetitions,
    reason = "terminal-agent protocol types use an explicit domain prefix"
)]

#[cfg(feature = "daemon-runtime")]
use std::time::Duration;

#[cfg(feature = "daemon-runtime")]
mod effort;
#[cfg(feature = "daemon-runtime")]
mod kill_switch_port;
#[cfg(feature = "daemon-runtime")]
mod manager;
#[cfg(feature = "daemon-runtime")]
mod manager_control;
#[cfg(feature = "daemon-runtime")]
mod manager_lifecycle;
#[cfg(feature = "daemon-runtime")]
mod manager_refresh;
#[cfg(feature = "daemon-runtime")]
mod manager_workspace_lifecycle;
#[cfg(feature = "daemon-runtime")]
mod model;
#[cfg(feature = "daemon-runtime")]
mod spawn;
#[cfg(feature = "daemon-runtime")]
mod storage_port;
#[cfg(feature = "daemon-runtime")]
mod support;
#[cfg(all(test, feature = "daemon-runtime"))]
mod tests;

#[cfg(all(test, feature = "daemon-runtime"))]
const DEFAULT_ROWS: u16 = harness_protocol::managed_agents::tui::DEFAULT_AGENT_TUI_ROWS;
#[cfg(all(test, feature = "daemon-runtime"))]
const DEFAULT_COLS: u16 = harness_protocol::managed_agents::tui::DEFAULT_AGENT_TUI_COLS;
#[cfg(feature = "daemon-runtime")]
const LIVE_REFRESH_INTERVAL: Duration = Duration::from_millis(100);

pub(crate) use harness_daemon_managed_agents::AgentTuiResizeRequestExt;
pub use harness_daemon_managed_agents::{
    AgentTuiBackend, AgentTuiLaunchProfile, AgentTuiProcess, AgentTuiSpawnSpec,
    PortablePtyAgentTuiBackend, TerminalScreenParser,
};
pub use harness_protocol::managed_agents::tui::{
    AgentTuiInput, AgentTuiInputRequest, AgentTuiInputRequestSchema, AgentTuiInputSequence,
    AgentTuiInputSequenceStep, AgentTuiKey, AgentTuiListResponse, AgentTuiResizeRequest,
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStartRequest, AgentTuiStatus, TerminalScreenSnapshot,
};
#[cfg(feature = "daemon-runtime")]
pub use manager::AgentTuiManagerHandle;
#[cfg(feature = "daemon-runtime")]
pub(crate) use manager_workspace_lifecycle::WorkspaceTerminalOwner;

pub(crate) use harness_daemon_managed_agents::{
    AgentTuiAttachState, AgentTuiInputWorker, AgentTuiSnapshotContext, ManagedTerminalOwner,
    deliver_deferred_prompts, signal_readiness_ready, snapshot_from_process,
    spawn_agent_tui_process,
};
#[cfg(all(test, feature = "daemon-runtime"))]
pub(crate) use harness_daemon_managed_agents::{resolved_command_argv, send_initial_prompt};
#[cfg(all(test, feature = "daemon-runtime"))]
pub(crate) use manager::ActiveAgentTui;
#[cfg(all(test, feature = "daemon-runtime"))]
pub(crate) use spawn::build_auto_join_prompt;
#[cfg(all(test, feature = "daemon-runtime"))]
pub(crate) use support::recorded_prompt_path;
