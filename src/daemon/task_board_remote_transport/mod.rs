//! Private controller-to-executor transport for fenced task-board attempts.
//!
//! These types are deliberately not part of the daemon HTTP, WebSocket, MCP,
//! or generated Swift contracts. The controller uses them only with an
//! operator-configured, certificate-pinned execution host.

pub(crate) mod client;
mod client_cleanup;
mod client_source_bundle_recovery;
pub(crate) mod controller;
mod controller_cleanup;
mod controller_renew_replay;
pub(crate) mod controller_offer_recovery;
mod controller_trust;
mod controller_cancel_replay;
mod controller_clock;
pub(crate) mod controller_source_bundle;
pub(crate) mod credentials;
pub(crate) mod routes;
pub(crate) mod routes_cleanup;
mod routes_status;
mod routes_source_bundle;
mod routes_support;
pub(crate) mod tls_pin;
pub(crate) mod wire;
mod wire_artifacts;
mod wire_conversion;
pub(crate) mod wire_cleanup;
mod wire_host;
mod wire_lifecycle;
mod wire_launch;
mod wire_limits;
mod wire_request_validation;
mod wire_result;
mod wire_source;
mod wire_source_bundle;
mod wire_source_bundle_recovery;
mod wire_validation;

#[cfg(test)]
mod client_tests;
#[cfg(test)]
mod controller_authority_barrier_tests;
#[cfg(test)]
pub(crate) mod controller_authority_test_support;
#[cfg(test)]
mod controller_authority_tests;
#[cfg(test)]
mod controller_artifact_tests;
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
mod wire_source_tests;
#[cfg(test)]
mod wire_source_bundle_tests;
#[cfg(test)]
mod wire_source_bundle_recovery_tests;
#[cfg(test)]
mod wire_tests;
