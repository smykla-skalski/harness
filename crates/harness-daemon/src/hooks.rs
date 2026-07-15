#[path = "../../../src/hooks/protocol/hook_result.rs"]
mod hook_result_types;
#[path = "../../../src/hooks/protocol/payloads.rs"]
mod payload_types;

pub mod adapters {
    pub use harness_protocol::agent::HookAgent;
}

pub mod protocol {
    pub mod hook_result {
        pub use super::super::hook_result_types::*;
    }

    pub mod payloads {
        pub use super::super::payload_types::*;
    }
}

pub mod runner_policy {
    pub use harness_hook::hook_runner_policy::*;
}
