#![deny(unsafe_code)]

#[path = "../../../src/errors/mod.rs"]
pub mod errors;
#[path = "../../../src/hooks/mod.rs"]
pub mod hooks;
#[path = "../../../src/kernel/mod.rs"]
pub mod kernel;

#[path = "../../../src/create/rules.rs"]
mod create_rules;
#[path = "../../../src/create/workflow.rs"]
mod create_workflow;

pub mod create {
    pub use crate::create_rules::*;
    pub use crate::create_workflow::*;

    pub mod workflow {
        pub use crate::create_workflow::*;
    }
}

pub mod feature_flags;

/// Agent hook adapters exposed for the root CLI compatibility facade.
pub mod hook_adapters {
    pub use crate::hooks::adapters::*;
}

/// Shared hook policy vocabulary exposed for daemon and setup consumers.
pub mod hook_runner_policy {
    pub use crate::hooks::runner_policy::*;
}

pub mod agents;
pub mod app;
pub mod infra;
pub mod platform;
pub mod run;
pub mod session;
pub mod setup;
pub mod telemetry;
pub mod workspace;
