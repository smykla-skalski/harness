use std::borrow::Cow;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CliErrorKind {
    #[error("{detail}")]
    WorkflowIo { detail: Cow<'static, str> },
    #[error("{detail}")]
    WorkflowParse { detail: Cow<'static, str> },
}

impl CliErrorKind {
    #[must_use]
    pub fn workflow_io(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::WorkflowIo {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn workflow_parse(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::WorkflowParse {
            detail: detail.into(),
        }
    }
}

#[derive(Debug)]
pub struct CliError {
    kind: CliErrorKind,
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.kind.fmt(formatter)
    }
}

impl std::error::Error for CliError {}

impl From<CliErrorKind> for CliError {
    fn from(kind: CliErrorKind) -> Self {
        Self { kind }
    }
}

impl From<std::io::Error> for CliError {
    fn from(error: std::io::Error) -> Self {
        CliErrorKind::workflow_io(error.to_string()).into()
    }
}
