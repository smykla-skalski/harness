use std::collections::BTreeSet;
use std::fmt;
use std::str::FromStr;

use crate::infra::blocks::BlockRequirement;
use crate::kernel::gate::Gate;
use crate::kernel::skills::SKILL_RUN;

pub const PREFLIGHT_REPLY_HEAD: &str = "suite:run/preflight:";

pub const MANIFEST_FIX_GATE: Gate = Gate {
    question: "suite:run/manifest-fix: how should this failure be handled?",
    options: &[
        "Fix for this run only",
        "Fix in suite and this run",
        "Skip this step",
        "Stop run",
    ],
};

pub const BUG_FOUND_GATE: Gate = Gate {
    question: "suite:run/bug-found: bug or failure detected during test execution",
    options: &["Fix now", "Continue and fix later", "Stop run"],
};

pub const SKILL_NAME: &str = SKILL_RUN;

#[must_use]
pub fn managed_cluster_binaries() -> BTreeSet<String> {
    BlockRequirement::ALL
        .iter()
        .flat_map(|requirement| requirement.denied_binaries().iter().copied())
        .map(ToString::to_string)
        .collect()
}

/// Preflight reply status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum PreflightReply {
    Pass,
    Fail,
}

impl PreflightReply {
    pub const ALL: &[Self] = &[Self::Pass, Self::Fail];
}

impl fmt::Display for PreflightReply {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Pass => "pass",
            Self::Fail => "fail",
        })
    }
}

impl FromStr for PreflightReply {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "pass" => Ok(Self::Pass),
            "fail" => Ok(Self::Fail),
            _ => Err(()),
        }
    }
}

/// Legacy Python scripts that are no longer allowed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum LegacyScript {
    ApplyTrackedManifest,
    CaptureState,
    ClusterLifecycle,
    InstallGatewayApiCrds,
    Preflight,
    RecordCommand,
    ValidateManifest,
}

impl LegacyScript {
    pub const ALL: &[Self] = &[
        Self::ApplyTrackedManifest,
        Self::CaptureState,
        Self::ClusterLifecycle,
        Self::InstallGatewayApiCrds,
        Self::Preflight,
        Self::RecordCommand,
        Self::ValidateManifest,
    ];

    #[must_use]
    pub fn is_denied(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for LegacyScript {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ApplyTrackedManifest => "apply_tracked_manifest.py",
            Self::CaptureState => "capture_state.py",
            Self::ClusterLifecycle => "cluster_lifecycle.py",
            Self::InstallGatewayApiCrds => "install_gateway_api_crds.py",
            Self::Preflight => "preflight.py",
            Self::RecordCommand => "record_command.py",
            Self::ValidateManifest => "validate_manifest.py",
        })
    }
}

impl FromStr for LegacyScript {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "apply_tracked_manifest.py" => Ok(Self::ApplyTrackedManifest),
            "capture_state.py" => Ok(Self::CaptureState),
            "cluster_lifecycle.py" => Ok(Self::ClusterLifecycle),
            "install_gateway_api_crds.py" => Ok(Self::InstallGatewayApiCrds),
            "preflight.py" => Ok(Self::Preflight),
            "record_command.py" => Ok(Self::RecordCommand),
            "validate_manifest.py" => Ok(Self::ValidateManifest),
            _ => Err(()),
        }
    }
}

/// Binaries the runner must not invoke directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum RunnerBinary {
    Gh,
}

impl RunnerBinary {
    pub const ALL: &[Self] = &[Self::Gh];

    #[must_use]
    pub fn is_denied(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for RunnerBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Gh => "gh",
        })
    }
}

impl FromStr for RunnerBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "gh" => Ok(Self::Gh),
            _ => Err(()),
        }
    }
}

/// Make target prefixes that imply cluster provisioning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum MakeTargetPrefix {
    K3d,
    Kind,
}

impl MakeTargetPrefix {
    pub const ALL: &[Self] = &[Self::K3d, Self::Kind];

    #[must_use]
    pub fn is_denied_target(target: &str) -> bool {
        Self::ALL.iter().any(|prefix| {
            let raw = match prefix {
                Self::K3d => "k3d/",
                Self::Kind => "kind/",
            };
            target.starts_with(raw)
        })
    }
}

impl fmt::Display for MakeTargetPrefix {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::K3d => "k3d/",
            Self::Kind => "kind/",
        })
    }
}

impl FromStr for MakeTargetPrefix {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "k3d/" => Ok(Self::K3d),
            "kind/" => Ok(Self::Kind),
            _ => Err(()),
        }
    }
}

/// Hints that indicate direct Envoy admin access.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum AdminEndpointHint {
    LocalhostEnvoy,
    ConfigDump,
    Clusters,
    Listeners,
    Routes,
}

impl AdminEndpointHint {
    pub const ALL: &[Self] = &[
        Self::LocalhostEnvoy,
        Self::ConfigDump,
        Self::Clusters,
        Self::Listeners,
        Self::Routes,
    ];

    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::LocalhostEnvoy => "localhost:9901",
            Self::ConfigDump => "/config_dump",
            Self::Clusters => "/clusters",
            Self::Listeners => "/listeners",
            Self::Routes => "/routes",
        }
    }

    #[must_use]
    pub fn contains_hint(word: &str) -> bool {
        Self::ALL.iter().any(|hint| word.contains(hint.as_str()))
    }
}

impl fmt::Display for AdminEndpointHint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for AdminEndpointHint {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .iter()
            .find(|hint| hint.as_str() == s)
            .copied()
            .ok_or(())
    }
}

/// Patterns that indicate direct access to task output files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum TaskOutputPattern {
    PrivateTmpClaude,
    TasksOutputGlob,
    TasksB8mPrefix,
}

impl TaskOutputPattern {
    pub const ALL: &[Self] = &[
        Self::PrivateTmpClaude,
        Self::TasksOutputGlob,
        Self::TasksB8mPrefix,
    ];

    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::PrivateTmpClaude => "/private/tmp/claude-",
            Self::TasksOutputGlob => "tasks/*.output",
            Self::TasksB8mPrefix => "tasks/b8m",
        }
    }

    #[must_use]
    pub fn matches_any(text: &str) -> bool {
        Self::ALL
            .iter()
            .any(|pattern| text.contains(pattern.as_str()))
    }

    pub const DENY_MESSAGE: &str = "do not read task output files directly. \
             Use the TaskOutput tool to check background task results, \
             or wait for the completion notification";
}

impl fmt::Display for TaskOutputPattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for TaskOutputPattern {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .iter()
            .find(|pattern| pattern.as_str() == s)
            .copied()
            .ok_or(())
    }
}

/// Binaries that mutate harness-managed run control files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ControlFileMutationBinary {
    Cp,
    Install,
    Mv,
    Tee,
}

impl ControlFileMutationBinary {
    pub const ALL: &[Self] = &[Self::Cp, Self::Install, Self::Mv, Self::Tee];

    #[must_use]
    pub fn is_mutation_binary(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for ControlFileMutationBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Cp => "cp",
            Self::Install => "install",
            Self::Mv => "mv",
            Self::Tee => "tee",
        })
    }
}

impl FromStr for ControlFileMutationBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "cp" => Ok(Self::Cp),
            "install" => Ok(Self::Install),
            "mv" => Ok(Self::Mv),
            "tee" => Ok(Self::Tee),
            _ => Err(()),
        }
    }
}

/// Binaries that read harness-managed run control files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ControlFileReadBinary {
    Cat,
    Head,
    Tail,
    Less,
    More,
}

impl ControlFileReadBinary {
    pub const ALL: &[Self] = &[Self::Cat, Self::Head, Self::Tail, Self::Less, Self::More];

    #[must_use]
    pub fn is_read_binary(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for ControlFileReadBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Cat => "cat",
            Self::Head => "head",
            Self::Tail => "tail",
            Self::Less => "less",
            Self::More => "more",
        })
    }
}

impl FromStr for ControlFileReadBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "cat" => Ok(Self::Cat),
            "head" => Ok(Self::Head),
            "tail" => Ok(Self::Tail),
            "less" => Ok(Self::Less),
            "more" => Ok(Self::More),
            _ => Err(()),
        }
    }
}

/// Binaries that mutate suite storage directories.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum SuiteMutationBinary {
    Cp,
    Install,
    Ln,
    Mkdir,
    Mv,
    Rm,
    Rmdir,
    Touch,
}

impl SuiteMutationBinary {
    pub const ALL: &[Self] = &[
        Self::Cp,
        Self::Install,
        Self::Ln,
        Self::Mkdir,
        Self::Mv,
        Self::Rm,
        Self::Rmdir,
        Self::Touch,
    ];

    #[must_use]
    pub fn is_mutation_binary(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for SuiteMutationBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Cp => "cp",
            Self::Install => "install",
            Self::Ln => "ln",
            Self::Mkdir => "mkdir",
            Self::Mv => "mv",
            Self::Rm => "rm",
            Self::Rmdir => "rmdir",
            Self::Touch => "touch",
        })
    }
}

impl FromStr for SuiteMutationBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "cp" => Ok(Self::Cp),
            "install" => Ok(Self::Install),
            "ln" => Ok(Self::Ln),
            "mkdir" => Ok(Self::Mkdir),
            "mv" => Ok(Self::Mv),
            "rm" => Ok(Self::Rm),
            "rmdir" => Ok(Self::Rmdir),
            "touch" => Ok(Self::Touch),
            _ => Err(()),
        }
    }
}

/// Shell and scripting interpreters that must not run control files directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ScriptInterpreter {
    Bash,
    Sh,
    Zsh,
    Node,
    Perl,
    Python,
    Ruby,
}

impl ScriptInterpreter {
    pub const ALL: &[Self] = &[
        Self::Bash,
        Self::Sh,
        Self::Zsh,
        Self::Node,
        Self::Perl,
        Self::Python,
        Self::Ruby,
    ];

    #[must_use]
    pub fn is_interpreter(name: &str) -> bool {
        if matches!(name, "bash" | "sh" | "zsh") {
            return true;
        }
        name.starts_with("node")
            || name.starts_with("perl")
            || name.starts_with("python")
            || name.starts_with("ruby")
    }
}

impl fmt::Display for ScriptInterpreter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Bash => "bash",
            Self::Sh => "sh",
            Self::Zsh => "zsh",
            Self::Node => "node",
            Self::Perl => "perl",
            Self::Python => "python",
            Self::Ruby => "ruby",
        })
    }
}

impl FromStr for ScriptInterpreter {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "bash" => Ok(Self::Bash),
            "sh" => Ok(Self::Sh),
            "zsh" => Ok(Self::Zsh),
            "node" => Ok(Self::Node),
            "perl" => Ok(Self::Perl),
            "python" => Ok(Self::Python),
            "ruby" => Ok(Self::Ruby),
            _ => Err(()),
        }
    }
}

/// Python binary names used for inline script detection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum PythonBinary {
    Python,
    Python3,
}

impl PythonBinary {
    pub const ALL: &[Self] = &[Self::Python, Self::Python3];

    #[must_use]
    pub fn is_python(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for PythonBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Python => "python",
            Self::Python3 => "python3",
        })
    }
}

impl FromStr for PythonBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "python" => Ok(Self::Python),
            "python3" => Ok(Self::Python3),
            _ => Err(()),
        }
    }
}

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
    pub const ALL: &[Self] = &[
        Self::Api,
        Self::Apply,
        Self::Bootstrap,
        Self::Capture,
        Self::Cli,
        Self::Closeout,
        Self::Cluster,
        Self::Diff,
        Self::Envoy,
        Self::Gateway,
        Self::Init,
        Self::InitRun,
        Self::Preflight,
        Self::Record,
        Self::Report,
        Self::Run,
        Self::RunnerState,
        Self::Service,
        Self::SessionStart,
        Self::SessionStop,
        Self::Token,
        Self::Validate,
    ];

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
