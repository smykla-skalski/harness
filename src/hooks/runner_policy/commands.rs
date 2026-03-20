use std::fmt;
use std::str::FromStr;

/// Harness subcommands that require tracked execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum TrackedHarnessSubcommand {
    Api,
    Apply,
    Bootstrap,
    Capture,
    Cli,
    Closeout,
    Cluster,
    Diff,
    Envoy,
    Gateway,
    Init,
    InitRun,
    Preflight,
    Record,
    Report,
    Run,
    RunnerState,
    Service,
    SessionStart,
    SessionStop,
    Token,
    Validate,
}

impl TrackedHarnessSubcommand {
    #[must_use]
    pub fn is_tracked(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for TrackedHarnessSubcommand {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Api => "api",
            Self::Apply => "apply",
            Self::Bootstrap => "bootstrap",
            Self::Capture => "capture",
            Self::Cli => "cli",
            Self::Closeout => "closeout",
            Self::Cluster => "cluster",
            Self::Diff => "diff",
            Self::Envoy => "envoy",
            Self::Gateway => "gateway",
            Self::Init => "init",
            Self::InitRun => "init-run",
            Self::Preflight => "preflight",
            Self::Record => "record",
            Self::Report => "report",
            Self::Run => "run",
            Self::RunnerState => "runner-state",
            Self::Service => "service",
            Self::SessionStart => "session-start",
            Self::SessionStop => "session-stop",
            Self::Token => "token",
            Self::Validate => "validate",
        })
    }
}

impl FromStr for TrackedHarnessSubcommand {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "api" => Ok(Self::Api),
            "apply" => Ok(Self::Apply),
            "bootstrap" => Ok(Self::Bootstrap),
            "capture" => Ok(Self::Capture),
            "cli" => Ok(Self::Cli),
            "closeout" => Ok(Self::Closeout),
            "cluster" => Ok(Self::Cluster),
            "diff" => Ok(Self::Diff),
            "envoy" => Ok(Self::Envoy),
            "gateway" => Ok(Self::Gateway),
            "init" => Ok(Self::Init),
            "init-run" => Ok(Self::InitRun),
            "preflight" => Ok(Self::Preflight),
            "record" => Ok(Self::Record),
            "report" => Ok(Self::Report),
            "run" => Ok(Self::Run),
            "runner-state" => Ok(Self::RunnerState),
            "service" => Ok(Self::Service),
            "session-start" => Ok(Self::SessionStart),
            "session-stop" => Ok(Self::SessionStop),
            "token" => Ok(Self::Token),
            "validate" => Ok(Self::Validate),
            _ => Err(()),
        }
    }
}
