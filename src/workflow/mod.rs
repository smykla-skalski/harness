//! Persisted workflow state machines for harness-guided sessions.
//!
//! `workflow::runner` tracks `suite:run` lifecycle transitions for an active run
//! directory, including preflight, execution, triage, and closeout state.
//! `workflow::author` does the same for the `suite:new` approval flow, where
//! discovery, review gates, and write rounds must survive tool invocations and
//! restarts. `workflow::engine` provides the shared versioned JSON repository
//! used by both state machines so schema evolution, locking, and atomic writes
//! stay consistent across harness workflows.

pub mod author;
pub mod engine;
pub mod runner;
