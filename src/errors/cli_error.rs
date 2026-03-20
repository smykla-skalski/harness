use std::error::Error;
use std::fmt;
use std::io;

use super::CliErrorKind;

/// The unified CLI error type, following the `io::Error` pattern.
///
/// Wraps a [`CliErrorKind`] with optional detail text and an optional
/// source error for chain traversal via `Error::source()`.
#[derive(Debug)]
pub struct CliError {
    kind: CliErrorKind,
    details: Option<String>,
    source: Option<Box<dyn Error + Send + Sync>>,
}

impl CliError {
    #[must_use]
    pub fn new(kind: CliErrorKind) -> Self {
        Self {
            kind,
            details: None,
            source: None,
        }
    }

    #[must_use]
    pub fn code(&self) -> &'static str {
        self.kind.code()
    }

    #[must_use]
    pub fn exit_code(&self) -> i32 {
        self.kind.exit_code()
    }

    #[must_use]
    pub fn hint(&self) -> Option<String> {
        self.kind.hint()
    }

    #[must_use]
    pub fn details(&self) -> Option<&str> {
        self.details.as_deref()
    }

    #[must_use]
    pub fn kind(&self) -> &CliErrorKind {
        &self.kind
    }

    #[must_use]
    pub fn message(&self) -> String {
        self.kind.to_string()
    }

    #[must_use]
    pub fn with_details(mut self, details: impl Into<String>) -> Self {
        self.details = Some(details.into());
        self
    }

    /// Attach an explicit source error for chain traversal.
    #[must_use]
    pub fn with_source(mut self, source: impl Error + Send + Sync + 'static) -> Self {
        self.source = Some(Box::new(source));
        self
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code(), self.kind)
    }
}

impl Error for CliError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        if let Some(ref source) = self.source {
            Some(source.as_ref())
        } else {
            Some(&self.kind)
        }
    }
}

impl From<CliErrorKind> for CliError {
    fn from(kind: CliErrorKind) -> Self {
        Self::new(kind)
    }
}

impl From<io::Error> for CliError {
    fn from(error: io::Error) -> Self {
        CliErrorKind::io(format!("IO error: {error}")).into()
    }
}

/// Format a [`CliError`] for display to stderr.
#[must_use]
pub fn render_error(error: &CliError) -> String {
    use std::fmt::Write;

    let mut buf = format!("ERROR [{}] {}", error.code(), error.kind);
    if let Some(hint) = error.hint() {
        let _ = write!(buf, "\nHint: {hint}");
    }
    if let Some(details) = error.details() {
        let _ = write!(buf, "\nDetails:\n{details}");
    }
    buf
}
