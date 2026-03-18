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
        CliErrorKind::command_failed(format!("[{}] {}", error.block, error.operation))
            .with_details(error.cause.to_string())
    }
}

#[cfg(test)]
mod tests {
    use std::io;

    use super::*;

    #[test]
    fn block_error_new_preserves_fields() {
        let err = BlockError::new("process", "run echo hello", io::Error::other("boom"));
        assert_eq!(err.block, "process");
        assert_eq!(err.operation, "run echo hello");
        assert_eq!(err.cause.to_string(), "boom");
    }

    #[test]
    fn block_error_display_format() {
        let err = BlockError::message("http", "request", "timeout");
        assert_eq!(err.to_string(), "[http] request: timeout");
    }

    #[test]
    fn block_error_source_is_cause() {
        let err = BlockError::message("docker", "inspect", "not found");
        let source = err.source().expect("expected source");
        assert_eq!(source.to_string(), "not found");
    }

    #[test]
    fn block_error_into_cli_error_code_and_message() {
        let err = BlockError::message("process", "run", "failed");
        let cli: CliError = err.into();
        assert_eq!(cli.code(), "KSRCLI004");
        assert_eq!(cli.message(), "command failed: [process] run");
        assert_eq!(cli.details(), Some("failed"));
    }

    #[test]
    fn block_error_message_without_typed_cause() {
        let err = BlockError::message("kubernetes", "apply", "bad manifest");
        assert_eq!(err.cause.to_string(), "bad manifest");
    }

    #[test]
    fn block_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<BlockError>();
    }
}
