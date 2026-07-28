// Deliberate public API facade, not scaffolding: `harness::session::adopter`,
// `index`, `ordering`, `persona`, `roles`, `service`, `storage`, `types`, and
// `wire` stay stable paths for their existing callers across daemon, hooks,
// and observe. `observe` and `transport` stay declared here rather than
// moving with the rest of the domain: they are separate, larger extractions
// tracked as their own follow-ups.
pub use harness_session::*;
pub mod observe;
pub mod transport;
