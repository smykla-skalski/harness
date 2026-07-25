//! Runtime platform support: cluster specs, compose topology, and validation helpers.

// Rendering compose topologies is only reachable through the `compose` cluster
// flows in `setup::cluster`, which carry the same gate.
#[cfg(feature = "compose")]
pub mod compose;
pub mod kubectl_validate;
pub mod runtime;
