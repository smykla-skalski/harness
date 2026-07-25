// Integration test crate root for scenarios that need the daemon runtime.
// Declares the submodules under tests/integration/ that reference symbols
// gated behind `full-runtime`, so only this target pays for the daemon,
// bridge and MCP dependency trees. Its sibling root tests/integration.rs owns
// everything else and reads the same directory, so a module changes target by
// moving its `mod` line rather than its file.

#![allow(
    clippy::absolute_paths,
    reason = "integration scenarios use explicit crate and std paths to keep setup readable"
)]
#![allow(
    clippy::cognitive_complexity,
    reason = "integration tests are clearer when full end-to-end flows stay together"
)]
#![allow(
    clippy::too_many_lines,
    reason = "integration tests keep complete scenario setup and assertions in one place"
)]

#[path = "integration"]
mod integration {
    mod acp_streaming;
    mod bridge_agent_tui;
    mod bridge_codex;
    mod bridge_discovery;
    mod bridge_lock_lifecycle;
    mod daemon_comparison;
    mod daemon_control;
    mod daemon_perf;
    mod daemon_sandbox_mode;
    pub mod helpers;
    mod policy_drift;

    // Everything else under `architecture` scans the source tree and needs no
    // runtime, so only this one file follows the daemon here. It keeps its
    // original module path so `documented_operations_match_contract` and the
    // rest of its tests answer to the same names as before.
    #[path = "architecture"]
    mod architecture {
        #[allow(
            dead_code,
            reason = "the light target uses the rest of this scanning helper module"
        )]
        mod helpers;

        #[path = "docs_and_policy"]
        mod docs_and_policy {
            mod openapi_contract;
        }
    }
}
