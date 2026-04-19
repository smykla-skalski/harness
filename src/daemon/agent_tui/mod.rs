#![expect(
    clippy::module_name_repetitions,
    reason = "terminal-agent protocol types use an explicit domain prefix"
)]

use std::time::Duration;

mod input;
mod manager;
mod manager_control;
mod manager_lifecycle;
mod manager_refresh;
mod model;
mod process;
mod readiness;
mod screen;
mod spawn;
mod support;
#[cfg(test)]
mod tests;

const DEFAULT_ROWS: u16 = 30;
const DEFAULT_COLS: u16 = 120;
const LIVE_REFRESH_INTERVAL: Duration = Duration::from_millis(100);
pub(super) const READINESS_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(test)]
const DEFAULT_WAIT_TIMEOUT: Duration = Duration::from_secs(5);

pub use input::{AgentTuiInput, AgentTuiKey};
pub use manager::AgentTuiManagerHandle;
pub use model::{
    AgentTuiBackend, AgentTuiInputRequest, AgentTuiLaunchProfile, AgentTuiListResponse,
    AgentTuiResizeRequest, AgentTuiSize, AgentTuiSnapshot, AgentTuiSpawnSpec, AgentTuiStartRequest,
    AgentTuiStatus, PortablePtyAgentTuiBackend,
};
pub use process::AgentTuiProcess;
pub use screen::{TerminalScreenParser, TerminalScreenSnapshot};

#[allow(unused_imports)]
pub(crate) use manager::ActiveAgentTui;
#[allow(unused_imports)]
pub(crate) use process::{AgentTuiAttachState, AgentTuiSnapshotContext, snapshot_from_process};
#[allow(unused_imports)]
pub(crate) use readiness::{ReadinessSignal, signal_readiness_ready};
#[allow(unused_imports)]
pub(crate) use spawn::{
    build_auto_join_prompt, deliver_deferred_prompts, resolved_command_argv, send_initial_prompt,
    skill_directory_flags, spawn_agent_tui_process, wait_for_readiness,
};
