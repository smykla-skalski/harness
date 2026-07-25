use std::fmt;
use std::str::FromStr;

use crate::kernel::skills::dirs;

/// Files within a run directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum RunFile {
    RunReport,
    RunStatus,
    RunMetadata,
    CurrentDeploy,
    CommandLog,
    ManifestIndex,
    RunnerState,
}

impl RunFile {
    pub const ALL: &[Self] = &[
        Self::RunReport,
        Self::RunStatus,
        Self::RunMetadata,
        Self::CurrentDeploy,
        Self::CommandLog,
        Self::ManifestIndex,
        Self::RunnerState,
    ];

    pub const CONTROL_HINT: &str =
        "use `harness run report group`, `harness run runner-state`, or `harness run finish`";

    pub const COMMAND_LOG_HINT: &str =
        "use `harness run record` or recorded command artifacts instead";

    #[must_use]
    pub const fn is_allowed(self) -> bool {
        !matches!(self, Self::RunnerState)
    }

    #[must_use]
    pub const fn is_direct_write_denied(self) -> bool {
        matches!(
            self,
            Self::RunReport | Self::RunStatus | Self::RunnerState | Self::CommandLog
        )
    }

    #[must_use]
    pub const fn is_harness_managed(self) -> bool {
        matches!(self, Self::RunReport | Self::RunStatus | Self::RunnerState)
    }

    #[must_use]
    pub const fn write_hint(self) -> &'static str {
        match self {
            Self::CommandLog => Self::COMMAND_LOG_HINT,
            _ => Self::CONTROL_HINT,
        }
    }
}

impl fmt::Display for RunFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::RunReport => "run-report.md",
            Self::RunStatus => "run-status.json",
            Self::RunMetadata => "run-metadata.json",
            Self::CurrentDeploy => "current-deploy.json",
            Self::CommandLog => "commands/command-log.md",
            Self::ManifestIndex => "manifests/manifest-index.md",
            Self::RunnerState => dirs::RUN_STATE_FILE,
        })
    }
}

impl FromStr for RunFile {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "run-report.md" => Ok(Self::RunReport),
            "run-status.json" => Ok(Self::RunStatus),
            "run-metadata.json" => Ok(Self::RunMetadata),
            "current-deploy.json" => Ok(Self::CurrentDeploy),
            "commands/command-log.md" => Ok(Self::CommandLog),
            "manifests/manifest-index.md" => Ok(Self::ManifestIndex),
            _ if s == dirs::RUN_STATE_FILE => Ok(Self::RunnerState),
            _ => Err(()),
        }
    }
}

/// Allowed subdirectories within a run directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum RunDir {
    Artifacts,
    Commands,
    Manifests,
    State,
}

impl RunDir {
    pub const ALL: &[Self] = &[
        Self::Artifacts,
        Self::Commands,
        Self::Manifests,
        Self::State,
    ];
}

impl fmt::Display for RunDir {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Artifacts => "artifacts",
            Self::Commands => "commands",
            Self::Manifests => "manifests",
            Self::State => "state",
        })
    }
}

impl FromStr for RunDir {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "artifacts" => Ok(Self::Artifacts),
            "commands" => Ok(Self::Commands),
            "manifests" => Ok(Self::Manifests),
            "state" => Ok(Self::State),
            _ => Err(()),
        }
    }
}
