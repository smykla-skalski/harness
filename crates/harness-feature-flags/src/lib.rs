//! Runtime hook feature flags: env-var-gated toggles the daemon reads at
//! startup and per-request, plus the triage escalation config they resolve
//! for `harness-task-board`.
//!
//! Every reader of these flags runs inside the daemon; it sat in the root
//! crate for historical reasons, not architectural ones. The root crate and
//! `harness-daemon` both depend on it as a normal crate and re-export it,
//! rather than one owning the module and the other mirroring its source.

#![deny(unsafe_code)]

pub mod feature_flags;
