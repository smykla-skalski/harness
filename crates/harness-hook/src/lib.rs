#![deny(unsafe_code)]

#[path = "../../../src/hooks/mod.rs"]
pub mod hooks;

#[path = "../../../src/create/workflow.rs"]
mod create_workflow;

pub mod create {
    pub use crate::create_workflow::*;

    pub mod workflow {
        pub use crate::create_workflow::*;
    }
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
