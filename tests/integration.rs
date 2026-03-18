// Integration test crate root.
// Declares all submodules under tests/integration/.

mod integration {
    mod architecture;
    pub mod helpers;

    mod cluster;
    mod commands;
    mod compact;
    mod hooks;
    mod preflight;
    mod universal;
}
