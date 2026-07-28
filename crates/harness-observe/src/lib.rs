//! Session log scanning and issue classification, kept in its own crate so
//! the classifier compiles exactly once instead of once per `#[path]`
//! include.

pub mod patterns;
mod text;

pub use text::{
    DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, redact_details, truncate_at, truncate_details,
};
