#[path = "../../../src/hooks/protocol/payloads.rs"]
mod payload_types;

pub mod adapters {
    pub use harness_protocol::agent::HookAgent;
}

pub mod protocol {
    // Re-exported rather than re-included so this crate has a single
    // `HookResult` type shared with harness-kernel.
    pub mod hook_result {
        pub use harness_kernel::errors::hook_result::*;
    }

    pub mod payloads {
        pub use super::super::payload_types::*;
    }
}

pub mod runner_policy {
    pub use harness_hook::hook_runner_policy::*;
}
