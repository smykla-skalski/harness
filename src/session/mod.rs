// Deliberate public API facade, not scaffolding: `harness::session::adopter`,
// `index`, `observe`, `ordering`, `persona`, `roles`, `storage`, `types`, and
// `wire` stay stable paths for their existing callers across daemon and
// hooks. `service` and `transport` are NOT part of this glob: they are
// explicitly declared below and shadow it, because they are user-facing
// command-surface modules that belong in this root crate rather than in the
// `harness-session` domain crate, mirroring `task_board`'s existing split
// between `harness-task-board` (domain) and `task_board::transport` (this
// crate). `harness-daemon` does not depend on this crate at all, so keeping
// these two modules here (instead of in `harness-session`, which
// `harness-daemon` does depend on) is what actually removes the
// daemon-dialing command surface from the daemon's build.
pub use harness_session::*;

pub mod service;
pub mod transport;
