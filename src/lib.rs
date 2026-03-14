// Foundation stubs - workers will remove these allows when implementing real code.
#![allow(
    clippy::must_use_candidate,
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::unnecessary_wraps,
    clippy::unused_self,
    clippy::needless_pass_by_value,
    clippy::doc_markdown,
    clippy::module_name_repetitions,
    clippy::struct_excessive_bools,
    clippy::too_many_lines,
    clippy::similar_names,
    clippy::return_self_not_must_use,
    clippy::implicit_hasher,
    clippy::map_unwrap_or,
    clippy::trivially_copy_pass_by_ref,
    clippy::wildcard_imports,
    unused
)]

pub mod authoring;
pub mod authoring_validate;
pub mod bootstrap;
pub mod cli;
pub mod cluster;
pub mod codec;
pub mod commands;
pub mod compact;
pub mod context;
pub mod core_defs;
pub mod ephemeral_metallb;
pub mod errors;
pub mod exec;
pub mod hook;
pub mod hook_debug;
pub mod hook_payloads;
pub mod hooks;
pub mod io;
pub mod kubectl_validate;
pub mod manifests;
pub mod prepared_suite;
pub mod resolve;
pub mod rules;
pub mod schema;
pub mod session_hook;
pub mod suite_defaults;
pub mod workflow;
