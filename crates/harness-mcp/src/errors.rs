use std::borrow::Cow;
use std::fmt;

/// Error categories needed by the standalone MCP transport.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CliErrorKind {
    #[error("{detail}")]
    WorkflowIo { detail: Cow<'static, str> },
}

impl CliErrorKind {
    #[must_use]
    pub fn workflow_io(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::WorkflowIo {
            detail: detail.into(),
        }
    }
}

/// Standalone CLI error preserving the root CLI's MCP-facing format.
#[derive(Debug)]
pub struct CliError {
    kind: CliErrorKind,
}

impl CliError {
    #[must_use]
    pub const fn exit_code(&self) -> i32 {
        5
    }

    #[must_use]
    pub const fn code(&self) -> &'static str {
        "WORKFLOW_IO"
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "[{}] {}", self.code(), self.kind)
    }
}

impl std::error::Error for CliError {}

impl From<CliErrorKind> for CliError {
    fn from(kind: CliErrorKind) -> Self {
        Self { kind }
    }
}

#[must_use]
pub fn render_error(error: &CliError) -> String {
    format!("ERROR [{}] {}", error.code(), error.kind)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workflow_error_preserves_root_cli_contract() {
        let error = CliError::from(CliErrorKind::workflow_io("serve failed"));

        assert_eq!(error.code(), "WORKFLOW_IO");
        assert_eq!(error.exit_code(), 5);
        assert_eq!(render_error(&error), "ERROR [WORKFLOW_IO] serve failed");
    }
}
