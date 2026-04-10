// Integration test crate root.
// Declares all submodules under tests/integration/.

mod integration {
    mod architecture;
    mod codex_bridge;
    mod daemon_comparison;
    mod daemon_control;
    mod daemon_perf;
    mod daemon_sandbox_mode;
    pub mod helpers;

    mod cluster;
    mod commands;
    mod compact;
    mod hooks;
    mod preflight;
    mod universal;
}
