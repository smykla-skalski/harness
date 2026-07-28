use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

/// Overall verdict for a tracked run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum Verdict {
    Pending,
    Pass,
    Fail,
    Aborted,
}

impl Verdict {
    #[must_use]
    pub fn is_finalized(self) -> bool {
        matches!(self, Self::Pass | Self::Fail | Self::Aborted)
    }
}

impl fmt::Display for Verdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => f.write_str("pending"),
            Self::Pass => f.write_str("pass"),
            Self::Fail => f.write_str("fail"),
            Self::Aborted => f.write_str("aborted"),
        }
    }
}

/// Per-group verdict recorded in run status and reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupVerdict {
    Pass,
    Fail,
    Skip,
}

impl fmt::Display for GroupVerdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pass => f.write_str("pass"),
            Self::Fail => f.write_str("fail"),
            Self::Skip => f.write_str("skip"),
        }
    }
}

impl FromStr for GroupVerdict {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "pass" => Ok(Self::Pass),
            "fail" => Ok(Self::Fail),
            "skip" => Ok(Self::Skip),
            _ => Err(()),
        }
    }
}
