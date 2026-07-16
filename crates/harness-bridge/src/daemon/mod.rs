pub const HARNESS_MONITOR_APP_GROUP_ID: &str = "Q498EB36N4.io.harnessmonitor";

#[must_use]
pub fn sandboxed_from_env() -> bool {
    std::env::var("HARNESS_SANDBOXED")
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim(),
                "1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON"
            )
        })
}

#[path = "../../../../src/daemon/agent_acp/mod.rs"]
pub mod agent_acp;
pub mod agent_tui;
#[path = "../../../../src/daemon/bridge/mod.rs"]
pub mod bridge;
#[path = "../../../../src/daemon/discovery/mod.rs"]
pub mod discovery;
pub mod protocol {
    pub use harness_protocol::daemon::StreamEvent;
}
pub mod state;
