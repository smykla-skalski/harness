#![expect(
    clippy::module_name_repetitions,
    reason = "terminal-agent protocol types use an explicit domain prefix"
)]

#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
use std::time::Duration;

#[cfg(feature = "daemon-runtime")]
mod effort;
mod input;
mod input_request;
#[cfg(feature = "daemon-runtime")]
mod manager;
#[cfg(feature = "daemon-runtime")]
mod manager_control;
#[cfg(feature = "daemon-runtime")]
mod manager_lifecycle;
#[cfg(feature = "daemon-runtime")]
mod manager_refresh;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
mod model;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
mod process;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
mod readiness;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
mod screen;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
mod spawn;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
mod support;
#[cfg(all(test, feature = "daemon-runtime"))]
mod tests;

#[cfg(all(test, feature = "daemon-runtime"))]
const DEFAULT_ROWS: u16 = harness_protocol::managed_agents::tui::DEFAULT_AGENT_TUI_ROWS;
#[cfg(all(test, feature = "daemon-runtime"))]
const DEFAULT_COLS: u16 = harness_protocol::managed_agents::tui::DEFAULT_AGENT_TUI_COLS;
#[cfg(feature = "daemon-runtime")]
const LIVE_REFRESH_INTERVAL: Duration = Duration::from_millis(100);
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub(super) const READINESS_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(all(test, feature = "daemon-runtime"))]
const DEFAULT_WAIT_TIMEOUT: Duration = Duration::from_secs(5);

pub use harness_protocol::managed_agents::tui::{
    AgentTuiListResponse, AgentTuiResizeRequest, AgentTuiSize, AgentTuiSnapshot,
    AgentTuiStartRequest, AgentTuiStatus, TerminalScreenSnapshot,
};
pub use input::{AgentTuiInput, AgentTuiKey};
pub use input_request::{AgentTuiInputRequest, AgentTuiInputSequence, AgentTuiInputSequenceStep};
#[cfg(feature = "daemon-runtime")]
pub use manager::AgentTuiManagerHandle;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub(crate) use model::AgentTuiResizeRequestExt;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub use model::{
    AgentTuiBackend, AgentTuiLaunchProfile, AgentTuiSpawnSpec, PortablePtyAgentTuiBackend,
};
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub use process::AgentTuiProcess;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub use screen::TerminalScreenParser;

#[cfg(all(test, feature = "daemon-runtime"))]
pub(crate) use manager::ActiveAgentTui;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub(crate) use process::AgentTuiInputWorker;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub(crate) use process::{AgentTuiAttachState, AgentTuiSnapshotContext, snapshot_from_process};
#[cfg(all(test, feature = "daemon-runtime"))]
pub(crate) use readiness::signal_readiness_ready;
#[cfg(all(test, feature = "daemon-runtime"))]
pub(crate) use spawn::{build_auto_join_prompt, resolved_command_argv, send_initial_prompt};
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub(crate) use spawn::{deliver_deferred_prompts, spawn_agent_tui_process};
