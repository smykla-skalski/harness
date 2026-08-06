//! Ports the managed-terminal-agent manager needs from `harness-daemon`,
//! ahead of the manager itself moving into this crate, plus the portable
//! terminal-agent PTY runtime (spawn, process, screen, readiness) that has
//! no database or session coupling and moved here directly.
//!
//! `harness-daemon` implements the port traits for its own concrete
//! database handle types. This crate never depends on `harness-daemon`, so
//! it stays the dependency direction that lets the manager eventually
//! relocate here without a cycle.

use std::time::Duration;

mod kill_switch;
mod model;
mod process;
mod readiness;
mod screen;
mod spawn;
mod storage;
mod support;

pub use harness_protocol::managed_agents::tui::{
    AgentTuiInput, AgentTuiInputSequence, AgentTuiKey,
};
pub use kill_switch::AgentTuiKillSwitch;
pub use model::{
    AgentTuiBackend, AgentTuiLaunchProfile, AgentTuiResizeRequest, AgentTuiResizeRequestExt,
    AgentTuiSize, AgentTuiSizeExt, AgentTuiSnapshot, AgentTuiSpawnSpec, AgentTuiStatus,
    PortablePtyAgentTuiBackend,
};
pub use process::{
    AgentTuiAttachState, AgentTuiInputWorker, AgentTuiProcess, AgentTuiSnapshotContext,
    snapshot_from_process,
};
pub use readiness::signal_readiness_ready;
pub use screen::TerminalScreenParser;
pub use spawn::{
    deliver_deferred_prompts, ensure_runtime_bootstrap, resolved_command_argv, send_initial_prompt,
    spawn_agent_tui_process, wait_for_readiness,
};
pub use storage::AsyncAgentTuiStorage;
pub use support::lock;

pub(crate) const READINESS_TIMEOUT: Duration = Duration::from_secs(10);
