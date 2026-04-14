mod agent_tui;
mod bridge_state;
mod capability_lifecycle;
mod client;
mod commands;
mod control;
mod core;
mod detached;
mod helpers;
mod runtime;
mod server;
mod types;

#[allow(unused_imports)]
pub(crate) use bridge_state::acquire_bridge_lock_exclusive;
pub use bridge_state::{
    LivenessMode, bridge_config_path, bridge_socket_path, bridge_state_path,
    codex_websocket_endpoint, ensure_host_context, host_bridge_manifest, load_running_bridge_state,
    pid_alive, read_bridge_state, running_codex_capability, status_report,
};
pub use client::BridgeClient;
pub use commands::BridgeCommand;
pub use control::{reconfigure_bridge, spawn_manifest_watcher, stop_bridge};
pub(crate) use runtime::probe_codex_readiness;
pub use types::{
    AgentTuiStartSpec, BRIDGE_CAPABILITY_AGENT_TUI, BRIDGE_CAPABILITY_CODEX,
    BRIDGE_LAUNCH_AGENT_LABEL, BridgeCapability, BridgeConfigArgs, BridgeInstallLaunchAgentArgs,
    BridgeReconfigureArgs, BridgeRemoveLaunchAgentArgs, BridgeStartArgs, BridgeState,
    BridgeStatusArgs, BridgeStatusReport, BridgeStopArgs, CODEX_BRIDGE_PORT_ENV,
    DEFAULT_CODEX_BRIDGE_PORT, compiled_capabilities,
};

#[cfg(test)]
mod tests;
