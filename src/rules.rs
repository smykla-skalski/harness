use std::fmt;
use std::str::FromStr;

// ── Skill identity (single source of truth) ──────────────────────────
//
// Change the literal inside each macro to rename a skill everywhere.
// The macro approach lets `concat!()` work in const position without
// pulling in `const_format`.

/// Expands to the `suite:run` skill name literal.
macro_rules! skill_run {
    () => {
        "suite:run"
    };
}

/// Expands to the `suite:new` skill name literal.
macro_rules! skill_new {
    () => {
        "suite:new"
    };
}

/// Skill identity for the test runner.
pub const SKILL_RUN: &str = skill_run!();
/// Skill identity for the suite author.
pub const SKILL_NEW: &str = skill_new!();
/// All recognized skill names (for CLI value parsers).
pub const SKILL_NAMES: &[&str] = &[SKILL_RUN, SKILL_NEW];

/// Filesystem-safe names (no colons) derived from skill identity.
pub mod skill_dirs {
    pub const RUN_STATE_FILE: &str = concat!("suite-run", "-state.json");
    pub const NEW_WORKSPACE: &str = "suite-new";
    pub const NEW_STATE_FILE: &str = concat!("suite-new", "-state.json");
}

/// A gated question with fixed options presented to the user.
pub struct Gate {
    pub question: &'static str,
    pub options: &'static [&'static str],
}

impl Gate {
    /// Returns `true` when `question` and `labels` match this gate exactly.
    #[must_use]
    pub fn matches(&self, question: &str, labels: &[impl AsRef<str>]) -> bool {
        question == self.question
            && labels.len() == self.options.len()
            && labels
                .iter()
                .zip(self.options)
                .all(|(a, b)| a.as_ref() == *b)
    }
}

/// Constants shared between suite:run and suite:new.
pub mod shared {
    use super::{FromStr, fmt};

    /// Required markdown sections in a group body.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[non_exhaustive]
    pub enum GroupSection {
        Configure,
        Consume,
        Debug,
    }

    impl GroupSection {
        pub const ALL: &[Self] = &[Self::Configure, Self::Consume, Self::Debug];

        /// The heading string for this section.
        #[must_use]
        pub const fn as_str(self) -> &'static str {
            match self {
                Self::Configure => "## Configure",
                Self::Consume => "## Consume",
                Self::Debug => "## Debug",
            }
        }

        /// Returns which required sections are absent from `text`.
        #[must_use]
        pub fn missing_from(text: &str) -> Vec<Self> {
            Self::ALL
                .iter()
                .filter(|s| !text.contains(s.as_str()))
                .copied()
                .collect()
        }
    }

    impl fmt::Display for GroupSection {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(self.as_str())
        }
    }

    impl FromStr for GroupSection {
        type Err = ();

        fn from_str(s: &str) -> Result<Self, Self::Err> {
            match s {
                "## Configure" => Ok(Self::Configure),
                "## Consume" => Ok(Self::Consume),
                "## Debug" => Ok(Self::Debug),
                _ => Err(()),
            }
        }
    }
}

/// Suite:run constants and type definitions.
pub mod suite_runner {
    use super::{FromStr, Gate, fmt};

    pub const SKILL_NAME: &str = super::SKILL_RUN;
    pub const AGENT_PREFLIGHT: &str = "preflight-worker";
    pub const PREFLIGHT_REPLY_HEAD: &str = concat!(skill_run!(), "/preflight:");

    pub const REPORT_LINE_LIMIT: usize = 220;
    pub const REPORT_CODE_BLOCK_LIMIT: usize = 4;

    pub const MANIFEST_FIX_TARGET_PREFIX: &str = "Suite target: ";

    pub const MANIFEST_FIX_GATE: Gate = Gate {
        question: concat!(
            skill_run!(),
            "/manifest-fix: how should this failure be handled?"
        ),
        options: &[
            "Fix for this run only",
            "Fix in suite and this run",
            "Skip this step",
            "Stop run",
        ],
    };

    pub const BUG_FOUND_GATE: Gate = Gate {
        question: concat!(
            skill_run!(),
            "/bug-found: bug or failure detected during test execution"
        ),
        options: &["Fix now", "Continue and fix later", "Stop run"],
    };

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
            "use `harness report group`, `harness runner-state`, or `harness closeout`";

        pub const COMMAND_LOG_HINT: &str =
            "use `harness record`, `harness run`, or recorded command artifacts instead";

        /// Part of the allowed run surface (everything except `RunnerState`).
        #[must_use]
        pub const fn is_allowed(self) -> bool {
            !matches!(self, Self::RunnerState)
        }

        /// Files that must not be written directly by the agent.
        #[must_use]
        pub const fn is_direct_write_denied(self) -> bool {
            matches!(
                self,
                Self::RunReport | Self::RunStatus | Self::RunnerState | Self::CommandLog
            )
        }

        /// Files fully managed by harness commands (no agent writes at all).
        #[must_use]
        pub const fn is_harness_managed(self) -> bool {
            matches!(self, Self::RunReport | Self::RunStatus | Self::RunnerState)
        }

        /// Hint text for denied writes.
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
                Self::RunnerState => super::skill_dirs::RUN_STATE_FILE,
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
                _ if s == super::skill_dirs::RUN_STATE_FILE => Ok(Self::RunnerState),
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

    /// Cluster binaries that must go through harness wrappers.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[non_exhaustive]
    pub enum ClusterBinary {
        Kubectl,
        KubectlValidate,
        Kumactl,
        Helm,
        Docker,
        K3d,
    }

    impl ClusterBinary {
        pub const ALL: &[Self] = &[
            Self::Kubectl,
            Self::KubectlValidate,
            Self::Kumactl,
            Self::Helm,
            Self::Docker,
            Self::K3d,
        ];

        /// Returns `true` when `name` matches a denied cluster binary.
        #[must_use]
        pub fn is_denied(name: &str) -> bool {
            Self::from_str(name).is_ok()
        }
    }

    impl fmt::Display for ClusterBinary {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(match self {
                Self::Kubectl => "kubectl",
                Self::KubectlValidate => "kubectl-validate",
                Self::Kumactl => "kumactl",
                Self::Helm => "helm",
                Self::Docker => "docker",
                Self::K3d => "k3d",
            })
        }
    }

    impl FromStr for ClusterBinary {
        type Err = ();

        fn from_str(s: &str) -> Result<Self, Self::Err> {
            match s {
                "kubectl" => Ok(Self::Kubectl),
                "kubectl-validate" => Ok(Self::KubectlValidate),
                "kumactl" => Ok(Self::Kumactl),
                "helm" => Ok(Self::Helm),
                "docker" => Ok(Self::Docker),
                "k3d" => Ok(Self::K3d),
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

        /// Returns `true` when `name` matches a denied legacy script filename.
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

        /// Returns `true` when `name` matches a denied runner binary.
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

        /// Returns `true` when `target` starts with a denied prefix.
        #[must_use]
        pub fn is_denied_target(target: &str) -> bool {
            Self::ALL.iter().any(|p| {
                let prefix = match p {
                    Self::K3d => "k3d/",
                    Self::Kind => "kind/",
                };
                target.starts_with(prefix)
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

        /// The string representation of this hint.
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

        /// Returns `true` when `word` contains any admin endpoint hint.
        #[must_use]
        pub fn contains_hint(word: &str) -> bool {
            Self::ALL.iter().any(|h| word.contains(h.as_str()))
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
                .find(|h| h.as_str() == s)
                .copied()
                .ok_or(())
        }
    }

    /// Patterns that indicate direct access to Claude's internal task output
    /// files. These must never be read by the runner - use the `TaskOutput` tool
    /// instead.
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

        /// The substring to search for in a command.
        #[must_use]
        pub const fn as_str(&self) -> &'static str {
            match self {
                Self::PrivateTmpClaude => "/private/tmp/claude-",
                Self::TasksOutputGlob => "tasks/*.output",
                Self::TasksB8mPrefix => "tasks/b8m",
            }
        }

        /// Returns `true` when `text` contains any task output pattern.
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

        /// Returns `true` when `name` matches a control-file mutation binary.
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

        /// Returns `true` when `name` matches a control-file read binary.
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

        /// Returns `true` when `name` matches a suite mutation binary.
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

        /// Returns `true` when `name` matches a script interpreter.
        ///
        /// Exact match for shell interpreters; prefix match for
        /// `node`, `perl`, `python`, `ruby` (e.g. "node14" matches).
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

        /// Parse from canonical name only (prefix matching is in `is_interpreter`).
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

        /// Returns `true` when `name` matches a python binary.
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

    /// Harness subcommands that require tracked execution (one per Bash call).
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[non_exhaustive]
    pub enum TrackedHarnessSubcommand {
        Api,
        Apply,
        Bootstrap,
        Capture,
        Closeout,
        Cluster,
        Diff,
        Envoy,
        Gateway,
        Init,
        InitRun,
        Kumactl,
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
            Self::Closeout,
            Self::Cluster,
            Self::Diff,
            Self::Envoy,
            Self::Gateway,
            Self::Init,
            Self::InitRun,
            Self::Kumactl,
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

        /// Returns `true` when `name` matches a tracked subcommand.
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
                Self::Closeout => "closeout",
                Self::Cluster => "cluster",
                Self::Diff => "diff",
                Self::Envoy => "envoy",
                Self::Gateway => "gateway",
                Self::Init => "init",
                Self::InitRun => "init-run",
                Self::Kumactl => "kumactl",
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
                "closeout" => Ok(Self::Closeout),
                "cluster" => Ok(Self::Cluster),
                "diff" => Ok(Self::Diff),
                "envoy" => Ok(Self::Envoy),
                "gateway" => Ok(Self::Gateway),
                "init" => Ok(Self::Init),
                "init-run" => Ok(Self::InitRun),
                "kumactl" => Ok(Self::Kumactl),
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
}

/// Suite:new constants and type definitions.
pub mod suite_author {
    use super::{FromStr, Gate, fmt};

    pub const SKILL_NAME: &str = super::SKILL_NEW;

    pub const PREWRITE_GATE: Gate = Gate {
        question: concat!(skill_new!(), "/prewrite: approve current proposal?"),
        options: &["Approve proposal", "Request changes", "Cancel"],
    };

    pub const POSTWRITE_GATE: Gate = Gate {
        question: concat!(skill_new!(), "/postwrite: approve saved suite?"),
        options: &["Approve suite", "Request changes", "Cancel"],
    };

    pub const COPY_GATE: Gate = Gate {
        question: concat!(skill_new!(), "/copy: copy run command?"),
        options: &["Copy command", "Skip"],
    };

    /// Kind of result artifact produced by the suite:new pipeline.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[non_exhaustive]
    pub enum ResultKind {
        Inventory,
        Coverage,
        Variants,
        Schema,
        Proposal,
        EditRequest,
    }

    impl ResultKind {
        pub const ALL: &[Self] = &[
            Self::Inventory,
            Self::Coverage,
            Self::Variants,
            Self::Schema,
            Self::Proposal,
            Self::EditRequest,
        ];
    }

    impl fmt::Display for ResultKind {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(match self {
                Self::Inventory => "inventory",
                Self::Coverage => "coverage",
                Self::Variants => "variants",
                Self::Schema => "schema",
                Self::Proposal => "proposal",
                Self::EditRequest => "edit-request",
            })
        }
    }

    impl FromStr for ResultKind {
        type Err = ();

        fn from_str(s: &str) -> Result<Self, Self::Err> {
            match s {
                "inventory" => Ok(Self::Inventory),
                "coverage" => Ok(Self::Coverage),
                "variants" => Ok(Self::Variants),
                "schema" => Ok(Self::Schema),
                "proposal" => Ok(Self::Proposal),
                "edit-request" => Ok(Self::EditRequest),
                _ => Err(()),
            }
        }
    }

    /// Named worker agents in the suite:new pipeline.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[non_exhaustive]
    pub enum Worker {
        CoverageReader,
        VariantAnalyzer,
        SchemaVerifier,
        SuiteWriter,
        BaselineWriter,
        GroupWriter,
    }

    impl Worker {
        pub const ALL: &[Self] = &[
            Self::CoverageReader,
            Self::VariantAnalyzer,
            Self::SchemaVerifier,
            Self::SuiteWriter,
            Self::BaselineWriter,
            Self::GroupWriter,
        ];
    }

    impl fmt::Display for Worker {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(match self {
                Self::CoverageReader => "coverage-reader",
                Self::VariantAnalyzer => "variant-analyzer",
                Self::SchemaVerifier => "schema-verifier",
                Self::SuiteWriter => "suite-writer",
                Self::BaselineWriter => "baseline-writer",
                Self::GroupWriter => "group-writer",
            })
        }
    }

    impl FromStr for Worker {
        type Err = ();

        fn from_str(s: &str) -> Result<Self, Self::Err> {
            match s {
                "coverage-reader" => Ok(Self::CoverageReader),
                "variant-analyzer" => Ok(Self::VariantAnalyzer),
                "schema-verifier" => Ok(Self::SchemaVerifier),
                "suite-writer" => Ok(Self::SuiteWriter),
                "baseline-writer" => Ok(Self::BaselineWriter),
                "group-writer" => Ok(Self::GroupWriter),
                _ => Err(()),
            }
        }
    }
}

/// Compact/handoff constants.
pub mod compact {
    pub const HANDOFF_VERSION: u32 = 1;
    pub const HISTORY_LIMIT: usize = 10;
    pub const CHAR_LIMIT: usize = 3500;
    pub const SECTION_CHAR_LIMIT: usize = 1600;
    pub const SECTION_LINE_LIMIT: usize = 25;
}

#[cfg(test)]
mod tests {
    #![allow(clippy::cognitive_complexity)]

    use super::*;

    // Generates all_count, display_roundtrip, and rejects_unknown tests for a string enum.
    macro_rules! test_string_enum {
        ($mod_name:ident, $type:path) => {
            mod $mod_name {
                use super::super::*;
                #[test]
                fn all_count() {
                    assert!(<$type>::ALL.len() > 0);
                }
                #[test]
                fn display_roundtrip() {
                    for v in <$type>::ALL {
                        let parsed: $type = v.to_string().parse().unwrap();
                        assert_eq!(*v, parsed);
                    }
                }
                #[test]
                fn rejects_unknown() {
                    assert!("__invalid__".parse::<$type>().is_err());
                }
            }
        };
    }

    // -- Gate --

    #[test]
    fn gate_matches_exact() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(gate.matches("test?", &["A", "B"]));
    }

    #[test]
    fn gate_rejects_wrong_question() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(!gate.matches("other?", &["A", "B"]));
    }

    #[test]
    fn gate_rejects_wrong_options() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(!gate.matches("test?", &["A", "C"]));
    }

    #[test]
    fn gate_rejects_wrong_length() {
        let gate = Gate {
            question: "test?",
            options: &["A", "B"],
        };
        assert!(!gate.matches("test?", &["A"]));
    }

    // -- GroupSection --

    test_string_enum!(group_section, shared::GroupSection);

    #[test]
    fn group_section_missing_from() {
        let text = "## Configure\nsome content\n## Debug\nmore content";
        let missing = shared::GroupSection::missing_from(text);
        assert_eq!(missing, vec![shared::GroupSection::Consume]);
    }

    #[test]
    fn group_section_missing_from_none() {
        let text = "## Configure\n## Consume\n## Debug";
        let missing = shared::GroupSection::missing_from(text);
        assert!(missing.is_empty());
    }

    // -- PreflightReply --

    test_string_enum!(preflight_reply, suite_runner::PreflightReply);

    // -- RunFile --

    test_string_enum!(run_file, suite_runner::RunFile);

    #[test]
    fn run_file_is_allowed() {
        use suite_runner::RunFile;
        assert!(RunFile::RunReport.is_allowed());
        assert!(RunFile::RunStatus.is_allowed());
        assert!(RunFile::RunMetadata.is_allowed());
        assert!(RunFile::CurrentDeploy.is_allowed());
        assert!(RunFile::CommandLog.is_allowed());
        assert!(RunFile::ManifestIndex.is_allowed());
        assert!(!RunFile::RunnerState.is_allowed());
        assert_eq!(RunFile::ALL.iter().filter(|f| f.is_allowed()).count(), 6);
    }

    #[test]
    fn run_file_is_direct_write_denied() {
        use suite_runner::RunFile;
        assert!(RunFile::RunReport.is_direct_write_denied());
        assert!(RunFile::RunStatus.is_direct_write_denied());
        assert!(RunFile::RunnerState.is_direct_write_denied());
        assert!(RunFile::CommandLog.is_direct_write_denied());
        assert!(!RunFile::RunMetadata.is_direct_write_denied());
        assert!(!RunFile::CurrentDeploy.is_direct_write_denied());
        assert!(!RunFile::ManifestIndex.is_direct_write_denied());
        assert_eq!(
            RunFile::ALL
                .iter()
                .filter(|f| f.is_direct_write_denied())
                .count(),
            4
        );
    }

    #[test]
    fn run_file_is_harness_managed() {
        use suite_runner::RunFile;
        assert!(RunFile::RunReport.is_harness_managed());
        assert!(RunFile::RunStatus.is_harness_managed());
        assert!(RunFile::RunnerState.is_harness_managed());
        assert!(!RunFile::CommandLog.is_harness_managed());
        assert_eq!(
            RunFile::ALL
                .iter()
                .filter(|f| f.is_harness_managed())
                .count(),
            3
        );
    }

    #[test]
    fn run_file_write_hint() {
        use suite_runner::RunFile;
        assert!(RunFile::CommandLog.write_hint().contains("harness record"));
        assert!(
            RunFile::RunReport
                .write_hint()
                .contains("harness report group")
        );
        assert!(
            RunFile::RunnerState
                .write_hint()
                .contains("harness runner-state")
        );
    }

    // -- RunDir --

    test_string_enum!(run_dir, suite_runner::RunDir);

    // -- ClusterBinary --

    test_string_enum!(cluster_binary, suite_runner::ClusterBinary);

    #[test]
    fn cluster_binary_is_denied() {
        assert!(suite_runner::ClusterBinary::is_denied("kubectl"));
        assert!(suite_runner::ClusterBinary::is_denied("kubectl-validate"));
        assert!(suite_runner::ClusterBinary::is_denied("kumactl"));
        assert!(suite_runner::ClusterBinary::is_denied("helm"));
        assert!(suite_runner::ClusterBinary::is_denied("docker"));
        assert!(suite_runner::ClusterBinary::is_denied("k3d"));
        assert!(!suite_runner::ClusterBinary::is_denied("harness"));
    }

    // -- LegacyScript --

    test_string_enum!(legacy_script, suite_runner::LegacyScript);

    #[test]
    fn legacy_script_is_denied() {
        assert!(suite_runner::LegacyScript::is_denied("preflight.py"));
        assert!(suite_runner::LegacyScript::is_denied("capture_state.py"));
        assert!(!suite_runner::LegacyScript::is_denied("my_script.py"));
    }

    // -- RunnerBinary --

    test_string_enum!(runner_binary, suite_runner::RunnerBinary);

    #[test]
    fn runner_binary_is_denied() {
        assert!(suite_runner::RunnerBinary::is_denied("gh"));
        assert!(!suite_runner::RunnerBinary::is_denied("git"));
    }

    // -- MakeTargetPrefix --

    test_string_enum!(make_target_prefix, suite_runner::MakeTargetPrefix);

    #[test]
    fn make_target_prefix_is_denied_target() {
        assert!(suite_runner::MakeTargetPrefix::is_denied_target("k3d/stop"));
        assert!(suite_runner::MakeTargetPrefix::is_denied_target(
            "kind/create"
        ));
        assert!(!suite_runner::MakeTargetPrefix::is_denied_target(
            "test/unit"
        ));
    }

    // -- AdminEndpointHint --

    test_string_enum!(admin_endpoint_hint, suite_runner::AdminEndpointHint);

    #[test]
    fn admin_endpoint_hint_contains_hint() {
        assert!(suite_runner::AdminEndpointHint::contains_hint(
            "localhost:9901"
        ));
        assert!(suite_runner::AdminEndpointHint::contains_hint(
            "wget -qO- localhost:9901/config_dump"
        ));
        assert!(!suite_runner::AdminEndpointHint::contains_hint(
            "google.com"
        ));
    }

    // -- TaskOutputPattern --

    test_string_enum!(task_output_pattern, suite_runner::TaskOutputPattern);

    #[test]
    fn task_output_pattern_matches_private_tmp() {
        assert!(suite_runner::TaskOutputPattern::matches_any(
            "cat /private/tmp/claude-501/sessions/abc/tasks/xyz.output"
        ));
    }

    #[test]
    fn task_output_pattern_matches_glob() {
        assert!(suite_runner::TaskOutputPattern::matches_any(
            "cat tasks/*.output"
        ));
    }

    #[test]
    fn task_output_pattern_matches_b8m() {
        assert!(suite_runner::TaskOutputPattern::matches_any(
            "cat tasks/b8m-something"
        ));
    }

    #[test]
    fn task_output_pattern_rejects_unrelated() {
        assert!(!suite_runner::TaskOutputPattern::matches_any(
            "cat /tmp/normal-file.txt"
        ));
    }

    // -- MANIFEST_FIX_GATE --

    #[test]
    fn manifest_fix_gate_options_count() {
        assert_eq!(suite_runner::MANIFEST_FIX_GATE.options.len(), 4);
    }

    #[test]
    fn manifest_fix_gate_matches() {
        let gate = &suite_runner::MANIFEST_FIX_GATE;
        assert!(gate.matches(gate.question, gate.options));
    }

    // -- BUG_FOUND_GATE --

    #[test]
    fn bug_found_gate_options_count() {
        assert_eq!(suite_runner::BUG_FOUND_GATE.options.len(), 3);
    }

    #[test]
    fn bug_found_gate_matches() {
        let gate = &suite_runner::BUG_FOUND_GATE;
        assert!(gate.matches(gate.question, gate.options));
    }

    #[test]
    fn bug_found_gate_question_contains_prefix() {
        assert!(
            suite_runner::BUG_FOUND_GATE
                .question
                .starts_with("suite:run/")
        );
    }

    // -- ResultKind --

    test_string_enum!(result_kind, suite_author::ResultKind);

    // -- Worker --

    test_string_enum!(worker, suite_author::Worker);

    // -- Suite:new gates --

    #[test]
    fn suite_author_gate_questions() {
        assert!(suite_author::PREWRITE_GATE.question.contains("prewrite"));
        assert!(suite_author::POSTWRITE_GATE.question.contains("postwrite"));
        assert!(suite_author::COPY_GATE.question.contains("copy"));
    }

    #[test]
    fn suite_author_gate_options() {
        assert_eq!(suite_author::PREWRITE_GATE.options.len(), 3);
        assert_eq!(suite_author::POSTWRITE_GATE.options.len(), 3);
        assert_eq!(suite_author::COPY_GATE.options.len(), 2);
    }

    // -- Report limits --

    #[test]
    fn report_limits_are_positive() {
        const { assert!(suite_runner::REPORT_LINE_LIMIT > 0) }
        const { assert!(suite_runner::REPORT_CODE_BLOCK_LIMIT > 0) }
        assert_eq!(suite_runner::REPORT_LINE_LIMIT, 220);
        assert_eq!(suite_runner::REPORT_CODE_BLOCK_LIMIT, 4);
    }

    // -- Compact --

    #[test]
    fn compact_constants() {
        assert_eq!(compact::HANDOFF_VERSION, 1);
        assert_eq!(compact::HISTORY_LIMIT, 10);
        assert_eq!(compact::CHAR_LIMIT, 3500);
        assert_eq!(compact::SECTION_CHAR_LIMIT, 1600);
        assert_eq!(compact::SECTION_LINE_LIMIT, 25);
    }

    // -- ControlFileMutationBinary --

    test_string_enum!(
        control_file_mutation_binary,
        suite_runner::ControlFileMutationBinary
    );

    #[test]
    fn control_file_mutation_binary_predicate() {
        assert!(suite_runner::ControlFileMutationBinary::is_mutation_binary(
            "cp"
        ));
        assert!(suite_runner::ControlFileMutationBinary::is_mutation_binary(
            "tee"
        ));
        assert!(!suite_runner::ControlFileMutationBinary::is_mutation_binary("cat"));
    }

    // -- ControlFileReadBinary --

    test_string_enum!(
        control_file_read_binary,
        suite_runner::ControlFileReadBinary
    );

    #[test]
    fn control_file_read_binary_predicate() {
        assert!(suite_runner::ControlFileReadBinary::is_read_binary("cat"));
        assert!(suite_runner::ControlFileReadBinary::is_read_binary("tail"));
        assert!(!suite_runner::ControlFileReadBinary::is_read_binary("cp"));
    }

    // -- SuiteMutationBinary --

    test_string_enum!(suite_mutation_binary, suite_runner::SuiteMutationBinary);

    #[test]
    fn suite_mutation_binary_predicate() {
        assert!(suite_runner::SuiteMutationBinary::is_mutation_binary("rm"));
        assert!(suite_runner::SuiteMutationBinary::is_mutation_binary(
            "touch"
        ));
        assert!(!suite_runner::SuiteMutationBinary::is_mutation_binary(
            "cat"
        ));
    }

    // -- ScriptInterpreter --

    test_string_enum!(script_interpreter, suite_runner::ScriptInterpreter);

    #[test]
    fn script_interpreter_predicate_exact() {
        assert!(suite_runner::ScriptInterpreter::is_interpreter("bash"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("sh"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("zsh"));
    }

    #[test]
    fn script_interpreter_predicate_prefix() {
        assert!(suite_runner::ScriptInterpreter::is_interpreter("node"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("node14"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("python3"));
        assert!(suite_runner::ScriptInterpreter::is_interpreter("ruby"));
        assert!(!suite_runner::ScriptInterpreter::is_interpreter("cat"));
    }

    // -- PythonBinary --

    test_string_enum!(python_binary, suite_runner::PythonBinary);

    #[test]
    fn python_binary_predicate() {
        assert!(suite_runner::PythonBinary::is_python("python"));
        assert!(suite_runner::PythonBinary::is_python("python3"));
        assert!(!suite_runner::PythonBinary::is_python("python2"));
    }

    // -- TrackedHarnessSubcommand --

    test_string_enum!(
        tracked_harness_subcommand,
        suite_runner::TrackedHarnessSubcommand
    );

    #[test]
    fn tracked_harness_subcommand_predicate() {
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked("apply"));
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked(
            "init-run"
        ));
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked(
            "runner-state"
        ));
        assert!(suite_runner::TrackedHarnessSubcommand::is_tracked("token"));
        assert!(!suite_runner::TrackedHarnessSubcommand::is_tracked(
            "authoring-show"
        ));
    }

    #[test]
    fn tracked_harness_subcommand_hyphenated_variants() {
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::InitRun.to_string(),
            "init-run"
        );
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::RunnerState.to_string(),
            "runner-state"
        );
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::SessionStart.to_string(),
            "session-start"
        );
        assert_eq!(
            suite_runner::TrackedHarnessSubcommand::SessionStop.to_string(),
            "session-stop"
        );
    }
}
