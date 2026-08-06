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

// `agent_acp`, `agent_tui`, and `bridge` swap to a thin re-export over the
// real `harness-daemon` crate under `daemon-runtime`: their daemon-only
// branches assume sibling modules (`service`, `db`, `codex_controller`,
// `session::service`) that only the real daemon crate carries, so the
// `#[path]`-mirrored copy below can only ever satisfy the default
// `bridge-runtime` build. `discovery`, `protocol`, and `state` need no such
// swap: none of their code is gated on `daemon-runtime` in a way this crate
// can't already satisfy on its own. `agent_tui`'s `bridge-runtime` branch is
// a re-export too, over `harness-daemon-managed-agents` rather than a
// `#[path]` mirror: the portable terminal-agent PTY runtime lives in that
// crate now, shared by both build modes instead of duplicated.
#[cfg(not(feature = "daemon-runtime"))]
#[path = "../../../../crates/harness-daemon/src/daemon/agent_acp/mod.rs"]
pub mod agent_acp;
#[cfg(feature = "daemon-runtime")]
pub mod agent_acp {
    pub use harness_daemon::daemon::agent_acp::*;
}
#[cfg(not(feature = "daemon-runtime"))]
pub mod agent_tui;
#[cfg(feature = "daemon-runtime")]
pub mod agent_tui {
    pub use harness_daemon::daemon::agent_tui::*;
}
#[cfg(not(feature = "daemon-runtime"))]
#[path = "../../../../crates/harness-daemon/src/daemon/bridge/mod.rs"]
pub mod bridge;
#[cfg(feature = "daemon-runtime")]
pub mod bridge {
    pub use harness_daemon::daemon::bridge::*;
}
pub mod discovery;
pub mod protocol {
    pub use harness_protocol::daemon::StreamEvent;
}
pub mod state;
