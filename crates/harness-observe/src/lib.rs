//! Session log scanning and issue classification, kept in its own crate so
//! the classifier compiles exactly once instead of once per `#[path]`
//! include.

pub mod application;
pub mod classifier;
#[cfg(feature = "cli")]
mod compare;
#[cfg(feature = "cli")]
mod context_cmd;
#[cfg(feature = "cli")]
pub mod dump;
mod issue_code;
#[cfg(feature = "cli")]
pub mod output;
pub mod patterns;
#[cfg(feature = "cli")]
mod scan;
mod session;
pub mod session_event;
mod text;
#[cfg(feature = "cli")]
pub mod transport;
pub mod types;
#[cfg(feature = "cli")]
pub mod watch;

#[cfg(test)]
mod tests;

pub use issue_code::compute_issue_id;
pub use text::{
    DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, redact_details, truncate_at, truncate_details,
};
