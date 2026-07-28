// Deliberate public API facade, not scaffolding: `harness::session::adopter`,
// `index`, `observe`, `ordering`, `persona`, `roles`, `service`, `storage`,
// `types`, and `wire` stay stable paths for their existing callers across
// daemon and hooks. `transport` stays declared here rather than moving with
// the rest of the domain: it is a separate, larger extraction tracked as its
// own follow-up.
pub use harness_session::*;
pub mod transport;
