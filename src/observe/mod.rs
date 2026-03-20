pub(crate) mod application;
pub(crate) mod classifier;
mod compare;
mod context_cmd;
mod doctor;
mod dump;
pub mod output;
pub(crate) mod patterns;
mod scan;
pub(crate) mod session;
mod text;
pub(crate) mod transport;
pub(crate) mod types;
mod watch;

#[cfg(test)]
mod tests;

pub use transport::{ObserveArgs, ObserveFilterArgs, ObserveMode, ObserveScanActionKind};

pub(crate) use text::{
    DUMP_TRUNCATE_LENGTH, MIN_DUMP_TEXT_LENGTH, redact_details, truncate_at, truncate_details,
};
