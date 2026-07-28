//! Session log scanning and issue classification, kept in its own crate so
//! the classifier compiles exactly once instead of once per `#[path]`
//! include.

pub mod application;
pub mod classifier;
mod compare;
mod context_cmd;
pub mod dump;
mod issue_code;
pub mod output;
pub mod patterns;
mod scan;
mod session;
pub mod session_event;
mod text;
pub mod transport;
pub mod types;
pub mod watch;

#[cfg(test)]
mod tests;

pub use issue_code::compute_issue_id;
pub use text::{
    DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, redact_details, truncate_at, truncate_details,
};
