//! Wire types for the private controller-to-executor transport that fences
//! task-board attempts, shared one-way by `crate::daemon::db` (persistence)
//! and `crate::daemon::task_board_remote_transport` (`controller`/`routes`).
//!
//! This module used to live inside `task_board_remote_transport` itself,
//! which made `db`'s ~157 references into it and `task_board_remote_transport`'s
//! own ~38 references back into `db` for persistence a genuine two-way cycle
//! as compilation units. Hoisting the wire types to this sibling breaks that
//! cycle: both dependents now reach one-way into here instead of into each
//! other.
//!
//! Every submodule keeps crate-wide visibility so both dependents can reach
//! it directly, matching how `wire`/`wire_cleanup` were already `pub(crate)`
//! before the hoist.

pub(crate) mod wire;
pub(crate) mod wire_artifacts;
pub(crate) mod wire_cleanup;
pub(crate) mod wire_conversion;
pub(crate) mod wire_host;
pub(crate) mod wire_launch;
pub(crate) mod wire_lifecycle;
pub(crate) mod wire_limits;
pub(crate) mod wire_request_validation;
pub(crate) mod wire_result;
pub(crate) mod wire_source;
pub(crate) mod wire_source_bundle;
pub(crate) mod wire_source_bundle_recovery;
pub(crate) mod wire_validation;

#[cfg(test)]
mod wire_cancel_tests;
#[cfg(test)]
mod wire_launch_tests;
#[cfg(test)]
mod wire_limits_tests;
#[cfg(test)]
mod wire_provenance_tests;
#[cfg(test)]
mod wire_result_tests;
#[cfg(test)]
mod wire_source_bundle_recovery_tests;
#[cfg(test)]
mod wire_source_bundle_tests;
#[cfg(test)]
mod wire_source_tests;
#[cfg(test)]
pub(crate) mod wire_tests;
