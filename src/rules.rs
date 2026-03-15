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
        Kumactl,
        Helm,
        Docker,
        K3d,
    }

    impl ClusterBinary {
        pub const ALL: &[Self] = &[
            Self::Kubectl,
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

        /// Returns `true` when `word` contains any admin endpoint hint.
        #[must_use]
        pub fn contains_hint(word: &str) -> bool {
            Self::ALL.iter().any(|h| {
                let hint = match h {
                    Self::LocalhostEnvoy => "localhost:9901",
                    Self::ConfigDump => "/config_dump",
                    Self::Clusters => "/clusters",
                    Self::Listeners => "/listeners",
                    Self::Routes => "/routes",
                };
                word.contains(hint)
            })
        }
    }

    impl fmt::Display for AdminEndpointHint {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(match self {
                Self::LocalhostEnvoy => "localhost:9901",
                Self::ConfigDump => "/config_dump",
                Self::Clusters => "/clusters",
                Self::Listeners => "/listeners",
                Self::Routes => "/routes",
            })
        }
    }

    impl FromStr for AdminEndpointHint {
        type Err = ();

        fn from_str(s: &str) -> Result<Self, Self::Err> {
            match s {
                "localhost:9901" => Ok(Self::LocalhostEnvoy),
                "/config_dump" => Ok(Self::ConfigDump),
                "/clusters" => Ok(Self::Clusters),
                "/listeners" => Ok(Self::Listeners),
                "/routes" => Ok(Self::Routes),
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
    use super::*;

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

    #[test]
    fn group_section_all_count() {
        assert_eq!(shared::GroupSection::ALL.len(), 3);
    }

    #[test]
    fn group_section_display_roundtrip() {
        for section in shared::GroupSection::ALL {
            let s = section.to_string();
            let parsed: shared::GroupSection = s.parse().unwrap();
            assert_eq!(*section, parsed);
        }
    }

    #[test]
    fn group_section_from_str_rejects_unknown() {
        assert!("## Unknown".parse::<shared::GroupSection>().is_err());
    }

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

    #[test]
    fn preflight_reply_all_count() {
        assert_eq!(suite_runner::PreflightReply::ALL.len(), 2);
    }

    #[test]
    fn preflight_reply_display_roundtrip() {
        for reply in suite_runner::PreflightReply::ALL {
            let s = reply.to_string();
            let parsed: suite_runner::PreflightReply = s.parse().unwrap();
            assert_eq!(*reply, parsed);
        }
    }

    #[test]
    fn preflight_reply_from_str_rejects_unknown() {
        assert!("maybe".parse::<suite_runner::PreflightReply>().is_err());
    }

    // -- RunFile --

    #[test]
    fn run_file_all_count() {
        assert_eq!(suite_runner::RunFile::ALL.len(), 7);
    }

    #[test]
    fn run_file_display_roundtrip() {
        for file in suite_runner::RunFile::ALL {
            let s = file.to_string();
            let parsed: suite_runner::RunFile = s.parse().unwrap();
            assert_eq!(*file, parsed);
        }
    }

    #[test]
    fn run_file_from_str_rejects_unknown() {
        assert!("unknown.txt".parse::<suite_runner::RunFile>().is_err());
    }

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

    #[test]
    fn run_dir_all_count() {
        assert_eq!(suite_runner::RunDir::ALL.len(), 4);
    }

    #[test]
    fn run_dir_display_roundtrip() {
        for dir in suite_runner::RunDir::ALL {
            let s = dir.to_string();
            let parsed: suite_runner::RunDir = s.parse().unwrap();
            assert_eq!(*dir, parsed);
        }
    }

    #[test]
    fn run_dir_from_str_rejects_unknown() {
        assert!("logs".parse::<suite_runner::RunDir>().is_err());
    }

    // -- ClusterBinary --

    #[test]
    fn cluster_binary_all_count() {
        assert_eq!(suite_runner::ClusterBinary::ALL.len(), 5);
    }

    #[test]
    fn cluster_binary_display_roundtrip() {
        for bin in suite_runner::ClusterBinary::ALL {
            let s = bin.to_string();
            let parsed: suite_runner::ClusterBinary = s.parse().unwrap();
            assert_eq!(*bin, parsed);
        }
    }

    #[test]
    fn cluster_binary_is_denied() {
        assert!(suite_runner::ClusterBinary::is_denied("kubectl"));
        assert!(suite_runner::ClusterBinary::is_denied("kumactl"));
        assert!(suite_runner::ClusterBinary::is_denied("helm"));
        assert!(suite_runner::ClusterBinary::is_denied("docker"));
        assert!(suite_runner::ClusterBinary::is_denied("k3d"));
        assert!(!suite_runner::ClusterBinary::is_denied("harness"));
    }

    // -- LegacyScript --

    #[test]
    fn legacy_script_all_count() {
        assert_eq!(suite_runner::LegacyScript::ALL.len(), 7);
    }

    #[test]
    fn legacy_script_display_roundtrip() {
        for script in suite_runner::LegacyScript::ALL {
            let s = script.to_string();
            let parsed: suite_runner::LegacyScript = s.parse().unwrap();
            assert_eq!(*script, parsed);
        }
    }

    #[test]
    fn legacy_script_is_denied() {
        assert!(suite_runner::LegacyScript::is_denied("preflight.py"));
        assert!(suite_runner::LegacyScript::is_denied("capture_state.py"));
        assert!(!suite_runner::LegacyScript::is_denied("my_script.py"));
    }

    // -- RunnerBinary --

    #[test]
    fn runner_binary_all_count() {
        assert_eq!(suite_runner::RunnerBinary::ALL.len(), 1);
    }

    #[test]
    fn runner_binary_display_roundtrip() {
        for bin in suite_runner::RunnerBinary::ALL {
            let s = bin.to_string();
            let parsed: suite_runner::RunnerBinary = s.parse().unwrap();
            assert_eq!(*bin, parsed);
        }
    }

    #[test]
    fn runner_binary_is_denied() {
        assert!(suite_runner::RunnerBinary::is_denied("gh"));
        assert!(!suite_runner::RunnerBinary::is_denied("git"));
    }

    // -- MakeTargetPrefix --

    #[test]
    fn make_target_prefix_all_count() {
        assert_eq!(suite_runner::MakeTargetPrefix::ALL.len(), 2);
    }

    #[test]
    fn make_target_prefix_display_roundtrip() {
        for prefix in suite_runner::MakeTargetPrefix::ALL {
            let s = prefix.to_string();
            let parsed: suite_runner::MakeTargetPrefix = s.parse().unwrap();
            assert_eq!(*prefix, parsed);
        }
    }

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

    #[test]
    fn admin_endpoint_hint_all_count() {
        assert_eq!(suite_runner::AdminEndpointHint::ALL.len(), 5);
    }

    #[test]
    fn admin_endpoint_hint_display_roundtrip() {
        for hint in suite_runner::AdminEndpointHint::ALL {
            let s = hint.to_string();
            let parsed: suite_runner::AdminEndpointHint = s.parse().unwrap();
            assert_eq!(*hint, parsed);
        }
    }

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

    // -- ResultKind --

    #[test]
    fn result_kind_all_count() {
        assert_eq!(suite_author::ResultKind::ALL.len(), 6);
    }

    #[test]
    fn result_kind_display_roundtrip() {
        for kind in suite_author::ResultKind::ALL {
            let s = kind.to_string();
            let parsed: suite_author::ResultKind = s.parse().unwrap();
            assert_eq!(*kind, parsed);
        }
    }

    #[test]
    fn result_kind_from_str_rejects_unknown() {
        assert!("unknown".parse::<suite_author::ResultKind>().is_err());
    }

    // -- Worker --

    #[test]
    fn worker_all_count() {
        assert_eq!(suite_author::Worker::ALL.len(), 6);
    }

    #[test]
    fn worker_display_roundtrip() {
        for worker in suite_author::Worker::ALL {
            let s = worker.to_string();
            let parsed: suite_author::Worker = s.parse().unwrap();
            assert_eq!(*worker, parsed);
        }
    }

    #[test]
    fn worker_from_str_rejects_unknown() {
        assert!("unknown-worker".parse::<suite_author::Worker>().is_err());
    }

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
}
