//! Multi-agent session foundation: role permissions, task ordering, persona
//! resolution, external-session adoption, the on-disk session index, session
//! storage/journal persistence, the session orchestration service, and
//! file-backed session observation.
//!
//! `transport` stays in the root crate for now: it is a separate, larger
//! extraction tracked as its own follow-up. Its remaining cross-references
//! into this crate resolve through the root crate's
//! `pub use harness_session::*;` facade the same way every other external
//! consumer's `crate::session::` path does.

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
