//! The Harness panel: a companion web service for self-service pairing.
//!
//! The panel authenticates a person against GitHub, records the account, and
//! shows them what the panel knows about it. It reaches the daemon only over
//! the daemon's public HTTP API, never through shared Rust code, which is why
//! it is a standalone package with no dependency on the `harness` crate.

pub mod assets;
pub mod config;
pub mod crypto;
pub mod daemon_client;
pub mod error;
pub mod github;
pub mod http;
pub mod serve;
pub mod store;
pub mod unit;

pub use config::PanelConfig;
pub use error::{ApiError, PanelError};
