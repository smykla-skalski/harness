// Integration test crate root.
// Declares all submodules under tests/integration/.

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

mod integration {
    mod acp_streaming;
    mod agent_transcripts;
    mod architecture;
    mod bridge_agent_tui;
    mod bridge_codex;
    mod bridge_discovery;
    mod bridge_lock_lifecycle;
    mod cluster;
    mod commands;
    mod compact;
    mod daemon_comparison;
    mod daemon_control;
    mod daemon_perf;
    mod daemon_sandbox_mode;
    pub mod helpers;
    mod hooks;
    mod install_workflow;
    mod mcp;
    mod policy_drift;
    mod preflight;
    mod sandbox;
    mod task_board_cli;
    mod universal;
    mod workspace;
}
