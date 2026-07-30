//! `discovery` moved natively into `harness-daemon-discovery`, which this
//! crate and `harness-daemon` now both depend on directly instead of each
//! compiling their own copy of the same file through separate `#[path]`
//! includes.

pub use harness_daemon_discovery::*;
