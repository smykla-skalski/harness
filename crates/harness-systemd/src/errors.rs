use std::borrow::Cow;
use std::error::Error;
use std::fmt;
use std::io;

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

    const fn code(&self) -> &'static str {
        match self {
            Self::WorkflowIo { .. } => "WORKFLOW_IO",
            Self::WorkflowParse { .. } => "WORKFLOW_PARSE",
        }
    }
}

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
    pub fn code(&self) -> &'static str {
        self.kind.code()
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "[{}] {}", self.code(), self.kind)
    }
}

impl Error for CliError {}

impl From<CliErrorKind> for CliError {
    fn from(kind: CliErrorKind) -> Self {
        Self { kind }
    }
}

impl From<io::Error> for CliError {
    fn from(error: io::Error) -> Self {
        CliErrorKind::workflow_io(format!("IO error: {error}")).into()
    }
}

#[must_use]
pub fn render_error(error: &CliError) -> String {
    format!("ERROR [{}] {}", error.code(), error.kind)
}
