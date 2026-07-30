// Route-contract types, HTTP paths, and route tables live in
// `harness_protocol::daemon::api_contract` (zero internal dependencies made
// them relocatable; see that module's own tests for the pure route-table
// invariants). Re-exported here, unchanged, so no external call site in this
// crate has to know the definitions moved.
pub use harness_protocol::daemon::api_contract::*;

// Route-vs-remote-scope parity can only be checked from this crate: it needs
// `crate::daemon::remote`, which cannot be a `harness-protocol` dependency
// without creating the cycle this relocation exists to avoid.
#[cfg(test)]
mod tests;
