#![deny(unsafe_code)]

pub mod app;
pub mod authoring;
#[cfg(test)]
mod codec;
pub mod compact;
pub mod core_defs;
pub mod errors;
pub mod hooks;
pub mod infra;
pub(crate) mod manifests;
pub mod observe;
pub mod platform;
pub mod rules;
pub mod run;
pub mod schema;
pub mod setup;
pub(crate) mod shell_parse;
pub(crate) mod suite_defaults;
