//! Multi-agent session foundation: role permissions, task ordering, persona
//! resolution, external-session adoption, the on-disk session index, session
//! storage/journal persistence, the session orchestration service,
//! file-backed session observation, and the CLI command-surface transport
//! layer over all of it.

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
pub mod transport;
// Deliberate public API facade, not scaffolding: `harness::session::types`
// stays a stable path for the root crate's existing callers. The physical
// `types/` files are not part of this crate's build; `harness-protocol`
// alone pulls them in with `#[path]` to give the session model types their
// one physical definition.
pub mod types {
    pub use harness_protocol::session::*;
}
pub mod wire;
