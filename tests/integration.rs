// Integration test crate root.
// Declares all submodules under tests/integration/.

mod integration {
    mod agent_assets;
    mod agent_transcripts;
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
    mod mcp;
    mod observability;

    mod cluster;
    mod commands;
    mod compact;
    mod grafana_connector;
    mod hooks;
    mod preflight;
    mod sandbox;
    mod universal;
    mod workspace;
}
