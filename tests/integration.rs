// Integration test crate root.
// Declares all submodules under tests/integration/.

mod integration {
    mod architecture;
    mod bridge_agent_tui;
    mod bridge_codex;
    mod bridge_discovery;
    mod bridge_lock_lifecycle;
    mod daemon_comparison;
    mod daemon_control;
    mod daemon_perf;
    mod daemon_sandbox_mode;
    pub mod helpers;
    mod install_workflow;

    mod cluster;
    mod commands;
    mod compact;
    mod hooks;
    mod preflight;
    mod universal;
}
