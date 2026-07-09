use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dns01ExecHookOperation {
    Present,
    Cleanup,
}

impl Dns01ExecHookOperation {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Present => "present",
            Self::Cleanup => "cleanup",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dns01ExecHookInvocation {
    program: String,
    args: Vec<String>,
}

impl Dns01ExecHookInvocation {
    pub(crate) fn new<const N: usize>(program: &str, args: [&str; N]) -> Self {
        Self {
            program: program.to_string(),
            args: args.into_iter().map(ToOwned::to_owned).collect(),
        }
    }

    #[must_use]
    pub fn program(&self) -> &str {
        &self.program
    }

    #[must_use]
    pub fn args(&self) -> &[String] {
        &self.args
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dns01ExecHookError {
    WrongProvider,
    MissingCommand,
    RunnerFailed(String),
}

impl Dns01ExecHookError {
    pub(crate) const fn runner_failed(detail: String) -> Self {
        Self::RunnerFailed(detail)
    }
}

impl fmt::Display for Dns01ExecHookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WrongProvider => write!(f, "DNS-01 exec hook requires the exec DNS provider"),
            Self::MissingCommand => write!(f, "DNS-01 exec hook command is required"),
            Self::RunnerFailed(detail) => write!(f, "DNS-01 exec hook failed: {detail}"),
        }
    }
}

impl Error for Dns01ExecHookError {}
