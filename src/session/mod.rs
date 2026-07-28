// Deliberate public API facade, not scaffolding: `harness::session::adopter`,
// `index`, `observe`, `ordering`, `persona`, `roles`, `service`, `storage`,
// `transport`, `types`, and `wire` stay stable paths for their existing
// callers across daemon and hooks.
pub use harness_session::*;
