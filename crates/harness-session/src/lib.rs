//! Multi-agent session foundation: role permissions, task ordering, persona
//! resolution, external-session adoption, the on-disk session index, session
//! storage/journal persistence, the session orchestration service, and
//! file-backed session observation.
//!
//! The CLI command-surface transport layer that used to live here moved to
//! the root crate's `session::transport`: it decides whether to dial a live
//! daemon, which is a user-facing concern rather than domain logic, and it
//! kept this domain crate compiling in daemon-connection code that
//! `harness-daemon` never needed. `service`'s own daemon-dialing halves split
//! the same way; see `service::mod`'s doc comments for the functions that
//! keep their former fused shape because a non-CLI, non-daemon production
//! consumer (`harness-hooks`) still needs it.

#![deny(unsafe_code)]

pub mod adopter;
pub mod canonicalize;
pub mod index;
pub mod observe;
pub mod ordering;
pub mod persona;
pub mod roles;
pub mod service;
pub mod storage;
// Deliberate public API facade, not scaffolding: `harness::session::types`
// stays a stable path for the root crate's existing callers. The physical
// `types/` files are not part of this crate's build; `harness-protocol`
// alone pulls them in with `#[path]` to give the session model types their
// one physical definition.
pub mod types {
    pub use harness_protocol::session::*;
}
pub mod wire;
