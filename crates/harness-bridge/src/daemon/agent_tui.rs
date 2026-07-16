use std::time::Duration;

#[path = "../../../../src/daemon/agent_tui/input.rs"]
mod input;
#[path = "../../../../src/daemon/agent_tui/input_request.rs"]
mod input_request;
#[path = "../../../../src/daemon/agent_tui/model.rs"]
mod model;
#[path = "../../../../src/daemon/agent_tui/process.rs"]
mod process;
#[path = "../../../../src/daemon/agent_tui/readiness.rs"]
mod readiness;
#[path = "../../../../src/daemon/agent_tui/screen.rs"]
mod screen;
#[path = "../../../../src/daemon/agent_tui/spawn.rs"]
mod spawn;
mod support;

pub(super) const READINESS_TIMEOUT: Duration = Duration::from_secs(10);

pub use harness_protocol::managed_agents::tui::{
    AgentTuiListResponse, AgentTuiResizeRequest, AgentTuiSize, AgentTuiSnapshot,
    AgentTuiStartRequest, AgentTuiStatus, TerminalScreenSnapshot,
};
pub use input::{AgentTuiInput, AgentTuiKey};
pub use input_request::{AgentTuiInputRequest, AgentTuiInputSequence, AgentTuiInputSequenceStep};
pub(crate) use model::AgentTuiResizeRequestExt;
pub use model::{
    AgentTuiBackend, AgentTuiLaunchProfile, AgentTuiSpawnSpec, PortablePtyAgentTuiBackend,
};
pub use process::AgentTuiProcess;
pub(crate) use process::{
    AgentTuiAttachState, AgentTuiInputWorker, AgentTuiSnapshotContext, snapshot_from_process,
};
pub use screen::TerminalScreenParser;
pub(crate) use spawn::{deliver_deferred_prompts, spawn_agent_tui_process};
