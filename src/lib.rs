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

#[doc(hidden)]
pub use crate::app::cli;
#[doc(hidden)]
pub use crate::infra::blocks;
#[doc(hidden)]
pub use crate::platform::cluster;
#[doc(hidden)]
pub use crate::platform::compose;
#[doc(hidden)]
pub use crate::platform::ephemeral_metallb;
#[doc(hidden)]
pub use crate::platform::kubectl_validate;
#[doc(hidden)]
pub use crate::platform::runtime;
#[doc(hidden)]
pub use crate::run::context;

#[doc(hidden)]
pub mod commands {
    pub use crate::authoring::commands as authoring;
    pub use crate::observe;
    pub use crate::run::RunDirArgs;
    pub use crate::run::commands as run;
    pub use crate::setup;
}

#[doc(hidden)]
pub mod workflow {
    pub use crate::authoring::workflow as author;
    pub use crate::infra::persistence;
    pub use crate::run::workflow as runner;
}
