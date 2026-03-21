use std::error::Error;
use std::fmt;

use crate::errors::{CliError, CliErrorKind};

/// Error type for block operations.
///
/// Carries the block name, operation description, and underlying cause.
/// Bridges into `CliError` via the `From` impl so block errors flow
/// through the existing error rendering pipeline.
#[derive(Debug)]
pub struct BlockError {
    /// Block identifier: `process`, `http`, `docker`, `kubernetes`, etc.
    pub block: &'static str,
    /// Human-readable operation description.
    pub operation: String,
    /// Underlying cause.
    pub cause: Box<dyn Error + Send + Sync>,
}

impl BlockError {
    /// Create a new block error.
    pub fn new(
        block: &'static str,
        operation: &str,
        cause: impl Error + Send + Sync + 'static,
    ) -> Self {
        Self {
            block,
            operation: operation.to_string(),
            cause: Box::new(cause),
        }
    }

    /// Create a block error from a string message (no underlying cause).
    pub fn message(block: &'static str, operation: &str, message: impl Into<String>) -> Self {
        Self {
            block,
            operation: operation.to_string(),
            cause: Box::new(SimpleError(message.into())),
        }
    }
}

impl fmt::Display for BlockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}: {}", self.block, self.operation, self.cause)
    }
}

impl Error for BlockError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&*self.cause)
    }
}

/// Simple string error for cases without an underlying typed error.
#[derive(Debug)]
struct SimpleError(String);

impl fmt::Display for SimpleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl Error for SimpleError {}

impl From<BlockError> for CliError {
    fn from(error: BlockError) -> Self {
        let details = error.cause.to_string();
        CliErrorKind::command_failed(format!("[{}] {}", error.block, error.operation))
            .with_details(details)
            .with_source(error)
    }
}

#[cfg(test)]
#[path = "error/tests.rs"]
mod tests;
