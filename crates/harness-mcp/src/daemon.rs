//! Shared daemon discovery and wire contracts used by the MCP proxy tools.

pub use harness_daemon_client::{discovery, state};

pub mod protocol {
    pub use harness_protocol::daemon::*;
}
