//! Remote daemon trust contracts.
//!
//! This crate owns remote roles and scopes, bearer authentication, client
//! identity, and pairing models. Daemon composition that still needs storage
//! or certificate runtime state remains in `harness-daemon`.

pub mod remote;
pub mod remote_auth;
pub mod remote_identity;
pub mod remote_pairing;

mod remote_crypto;
