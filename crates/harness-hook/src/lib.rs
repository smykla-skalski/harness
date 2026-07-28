#![deny(unsafe_code)]

pub mod hooks {
    pub use harness_hooks::*;
}

/// Agent hook adapters exposed for the root CLI compatibility facade.
pub mod hook_adapters {
    pub use crate::hooks::adapters::*;
}

pub mod agents;
pub mod app;
pub mod infra;
pub mod session;
pub mod setup;
pub mod telemetry;
pub mod workspace;
