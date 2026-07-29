//! Runtime hook feature flags: env-var-gated toggles the daemon reads at
//! startup and per-request, plus the triage escalation config they resolve
//! for `harness-task-board`.
//!
//! This is a dependency-free leaf whose only consumer is the daemon; it sat
//! in the root crate for historical reasons, not architectural ones. Both
//! the root crate and `harness-daemon` depend on it as a normal crate.

#![deny(unsafe_code)]

pub mod feature_flags;
