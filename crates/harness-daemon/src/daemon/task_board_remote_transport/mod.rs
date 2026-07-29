//! Private controller-to-executor transport for fenced task-board attempts.
//!
//! These types are deliberately not part of the daemon HTTP, WebSocket, MCP,
//! or generated Swift contracts. The controller uses them only with an
//! operator-configured, certificate-pinned execution host.
//!
//! The wire types this transport serializes live in the sibling
//! `crate::daemon::task_board_remote_wire` module, not here: `db` needed a
//! one-way dependency on them instead of the two-way cycle it had with this
//! module, so `wire.rs`/`wire_*.rs` hoisted out to a shared sibling both `db`
//! and this module's `controller`/`routes` code depend on.

pub(crate) mod client;
mod client_cleanup;
mod client_source_bundle_recovery;
pub(crate) mod controller;
mod controller_cancel_replay;
mod controller_cleanup;
mod controller_clock;
pub(crate) mod controller_offer_recovery;
mod controller_phases;
mod controller_renew_replay;
pub(crate) mod controller_source_bundle;
mod controller_trust;
pub(crate) mod credentials;
pub(crate) mod routes;
pub(crate) mod routes_cleanup;
pub(crate) mod routes_source_bundle;
mod routes_status;
mod routes_support;
pub(crate) mod tls_pin;

#[cfg(test)]
mod client_tests;
#[cfg(test)]
mod controller_artifact_tests;
#[cfg(test)]
mod controller_authority_barrier_tests;
#[cfg(test)]
pub(crate) mod controller_authority_test_support;
#[cfg(test)]
mod controller_authority_tests;
#[cfg(test)]
mod controller_cancel_authority_tests;
#[cfg(test)]
mod controller_cancel_tests;
#[cfg(test)]
mod controller_claim_receipt_tests;
#[cfg(test)]
mod controller_late_response_tests;
#[cfg(test)]
mod controller_observation_tests;
#[cfg(test)]
mod controller_offer_replay_tests;
#[cfg(test)]
mod controller_prepared_test_support;
#[cfg(test)]
mod controller_settlement_tests;
#[cfg(test)]
mod controller_source_bundle_tests;
#[cfg(test)]
mod controller_status_cancel_tests;
#[cfg(test)]
mod controller_tests;
#[cfg(test)]
mod controller_trust_fence_tests;
#[cfg(test)]
mod credentials_tests;
#[cfg(test)]
mod routes_status_tests;
