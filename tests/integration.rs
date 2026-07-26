// Integration test crate root for scenarios the daemon runtime does not reach.
// Declares the submodules under tests/integration/ that compile without
// `full-runtime`, so running this target on its own links a library built
// without axum, sqlx, hyper, rustls and the rest of that dependency tree. It
// does not forbid the feature: enabling it, as the full gate does, links the
// larger library here too. Its sibling root tests/integration_daemon.rs owns
// the modules that do need those symbols and reads the same directory, so a
// module changes target by moving its `mod` line rather than its file.

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
    mod agent_transcripts;
    mod architecture;
    mod cluster;
    mod commands;
    mod compact;
    pub mod helpers;
    mod install_workflow;
    mod mcp;
    mod preflight;
    mod sandbox;
    mod task_board_cli;
    mod universal;
    mod workspace;
}
