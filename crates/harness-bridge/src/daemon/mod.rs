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

#[path = "../../../../crates/harness-daemon/src/daemon/agent_acp/mod.rs"]
pub mod agent_acp;
pub mod agent_tui;
#[path = "../../../../crates/harness-daemon/src/daemon/bridge/mod.rs"]
pub mod bridge;
#[path = "../../../../crates/harness-daemon/src/daemon/discovery/mod.rs"]
pub mod discovery;
#[path = "../../../../crates/harness-daemon/src/daemon/remote_redaction.rs"]
pub(crate) mod remote_redaction;
pub mod protocol {
    pub use harness_protocol::daemon::StreamEvent;
}
pub mod state;
