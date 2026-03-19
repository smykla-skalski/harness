#![deny(unsafe_code)]

pub mod app;
pub mod authoring;
#[cfg(test)]
mod codec;
pub mod core_defs;
pub mod errors;
pub mod hooks;
pub mod infra;
pub mod kernel;
pub(crate) mod manifests;
pub mod observe;
pub mod platform;
pub mod run;
pub mod schema;
pub mod setup;
pub(crate) mod suite_defaults;
pub mod workspace;
