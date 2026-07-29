//! Wire types for the private controller-to-executor transport that fences
//! task-board attempts, shared one-way by `harness-daemon`'s `db`
//! (persistence) and its `task_board_remote_transport` (`controller`/
//! `routes`).
//!
//! This module used to live inside `harness-daemon` itself, first as part of
//! `task_board_remote_transport`, then hoisted to the sibling
//! `daemon::task_board_remote_wire` to break a two-way cycle between `db` and
//! `task_board_remote_transport` as compilation units. That module-level fix
//! reappeared one level up once `db` was slated to become its own crate:
//! either dependent crate defining these types would force the other to
//! depend on it, recreating the same cycle at the crate boundary. Hoisting
//! the wire types here instead lets both dependents reach one-way into this
//! crate, which they already depend on for the task-board domain types these
//! wire types carry (`TaskBoardExecutionPhase`, `TaskBoardWorkflowKind`, and
//! friends), instead of into each other.
//!
//! Every submodule is fully `pub` so both dependents, now in a different
//! crate, can still reach it directly - the same crate-wide reach
//! `pub(crate)` gave them back when this module and its dependents shared
//! one crate.

pub mod wire;
pub mod wire_artifacts;
pub mod wire_cleanup;
pub mod wire_conversion;
pub mod wire_host;
pub mod wire_launch;
pub mod wire_lifecycle;
pub mod wire_limits;
pub mod wire_request_validation;
pub mod wire_result;
pub mod wire_source;
pub mod wire_source_bundle;
pub mod wire_source_bundle_recovery;
pub mod wire_validation;

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
pub mod wire_tests;
