use std::error::Error;
use std::fmt;
use std::io;

use crate::hook::{Decision, HookResult};

/// Enum of all CLI error kinds, following the `io::ErrorKind` pattern.
///
/// Each variant carries its data as fields - no runtime template rendering.
/// `Display` is derived by thiserror from the `#[error("...")]` attributes.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum CliErrorKind {
    // --- Input validation (exit 3) ---
    #[error("command args must not be empty")]
    EmptyCommandArgs,

    #[error("missing required tools: {tools}")]
    MissingTools { tools: String },

    #[error("unsafe name: {name} (must not contain path separators or \"..\")")]
    UnsafeName { name: String },

    // --- Command execution (exit 4) ---
    #[error("command failed: {command}")]
    CommandFailed { command: String },

    // --- Run lifecycle (exit 5) ---
    #[error("missing current run pointer")]
    MissingRunPointer,

    #[error("missing required closeout artifact: {rel}")]
    MissingCloseoutArtifact { rel: String },

    #[error("run is missing a final state capture")]
    MissingStateCapture,

    #[error("run overall verdict is still pending")]
    VerdictPending,

    #[error("missing run context value: {field}")]
    MissingRunContextValue { field: String },

    #[error("missing explicit run location for run id: {run_id}")]
    MissingRunLocation { run_id: String },

    #[error("run directory already exists: {run_dir}")]
    RunDirExists { run_dir: String },

    #[error("run has no recorded status")]
    MissingRunStatus,

    #[error("run group is already recorded: {group_id}")]
    RunGroupAlreadyRecorded { group_id: String },

    #[error("group is not present in the run plan: {group_id}")]
    RunGroupNotFound { group_id: String },

    // --- File/path errors (exit 5) ---
    #[error("missing file: {path}")]
    MissingFile { path: String },

    #[error("invalid JSON in {path}")]
    InvalidJson { path: String },

    #[error("path not found: {dotted_path}")]
    PathNotFound { dotted_path: String },

    // --- Schema/structure validation (exit 5) ---
    #[error("{label} must be a mapping")]
    NotAMapping { label: String },

    #[error("{label} must use string keys")]
    NotStringKeys { label: String },

    #[error("{label} must be a list")]
    NotAList { label: String },

    #[error("{label} must contain only strings")]
    NotAllStrings { label: String },

    #[error("missing YAML frontmatter")]
    MissingFrontmatter,

    #[error("unterminated YAML frontmatter")]
    UnterminatedFrontmatter,

    #[error("missing required fields: {label}: {fields}")]
    MissingFields { label: String, fields: String },

    #[error("field type mismatch in {label}: {field} (expected {expected})")]
    FieldTypeMismatch {
        label: String,
        field: String,
        expected: String,
    },

    #[error("missing sections: {label}: {sections}")]
    MissingSections { label: String, sections: String },

    #[error("markdown row shape mismatch")]
    MarkdownShapeMismatch,

    // --- Gateway ---
    #[error("unable to resolve Gateway API version from go.mod")]
    GatewayVersionMissing,

    #[error("Gateway API CRDs are not installed")]
    GatewayCrdsMissing,

    #[error("downloaded Gateway API manifest is empty: {path}")]
    GatewayDownloadEmpty { path: String },

    // --- Kubernetes/cluster ---
    #[error("no resource kinds found in {manifest}")]
    NoResourceKinds { manifest: String },

    #[error("route {route_match} not found")]
    RouteNotFound { route_match: String },

    #[error("unable to find local kumactl")]
    KumactlNotFound,

    #[error("tracked kubectl command requires an active local cluster kubeconfig")]
    TrackedKubectlRequired,

    #[error("kubectl target override is not allowed in tracked runs: {flag}")]
    KubectlTargetOverrideForbidden { flag: String },

    #[error("unknown tracked cluster member: {cluster}")]
    UnknownTrackedCluster { cluster: String, choices: String },

    #[error("tracked kubeconfig is not a local harness cluster: {path}")]
    NonLocalKubeconfig { path: String },

    // --- Envoy ---
    #[error("envoy config type not found: {type_name}")]
    EnvoyConfigTypeNotFound { type_name: String },

    #[error("envoy live capture requires: {fields}")]
    EnvoyCaptureArgsRequired { fields: String },

    // --- Report (exit 1) ---
    #[error("report exceeds line limit: {count}>{limit}")]
    ReportLineLimit { count: String, limit: String },

    #[error("report exceeds code block limit: {count}>{limit}")]
    ReportCodeBlockLimit { count: String, limit: String },

    #[error("no recorded artifact found for evidence label: {label}")]
    EvidenceLabelNotFound { label: String },

    #[error("group report requires at least one evidence input")]
    ReportGroupEvidenceRequired,

    // --- Authoring ---
    #[error("missing active suite-author authoring session")]
    AuthoringSessionMissing,

    #[error("missing suite-author payload input")]
    AuthoringPayloadMissing,

    #[error("invalid suite-author {kind} payload: {details}")]
    AuthoringPayloadInvalid { kind: String, details: String },

    #[error("missing saved suite-author payload: {kind}")]
    AuthoringShowKindMissing { kind: String },

    #[error("suite amendments entry is missing or empty: {path}")]
    AmendmentsRequired { path: String },

    #[error("suite-author manifest validation failed: {targets}")]
    AuthoringValidateFailed { targets: String },

    #[error("suite-author local validator decision is still required")]
    KubectlValidateDecisionRequired,

    #[error("suite-author local validator is unavailable")]
    KubectlValidateUnavailable,

    // --- IO/serialization (exit 1) ---
    #[error("{detail}")]
    Io { detail: String },

    #[error("serialization failed: {detail}")]
    Serialize { detail: String },

    #[error("{detail}")]
    HookPayloadInvalid { detail: String },

    #[error("{detail}")]
    ClusterError { detail: String },

    #[error("{detail}")]
    UsageError { detail: String },

    // --- Workflow (exit 5) ---
    #[error("{detail}")]
    WorkflowIo { detail: String },

    #[error("{detail}")]
    WorkflowParse { detail: String },

    #[error("unsupported workflow schema version: {detail}")]
    WorkflowVersion { detail: String },

    #[error("serialization failed: {detail}")]
    WorkflowSerialize { detail: String },

    #[error("{detail}")]
    JsonParse { detail: String },
}

impl CliErrorKind {
    /// Error code identifying this error kind.
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::EmptyCommandArgs => "KSRCLI001",
            Self::MissingTools { .. } => "KSRCLI002",
            Self::CommandFailed { .. } => "KSRCLI004",
            Self::MissingRunPointer => "KSRCLI005",
            Self::MissingCloseoutArtifact { .. } => "KSRCLI006",
            Self::MissingStateCapture => "KSRCLI007",
            Self::VerdictPending => "KSRCLI008",
            Self::MissingRunContextValue { .. } => "KSRCLI009",
            Self::NotAMapping { .. } => "KSRCLI010",
            Self::NotStringKeys { .. } => "KSRCLI011",
            Self::NotAList { .. } => "KSRCLI012",
            Self::NotAllStrings { .. } => "KSRCLI013",
            Self::MissingFile { .. } => "KSRCLI014",
            Self::MissingFrontmatter => "KSRCLI015",
            Self::UnterminatedFrontmatter => "KSRCLI016",
            Self::PathNotFound { .. } => "KSRCLI017",
            Self::MissingRunLocation { .. } => "KSRCLI018",
            Self::InvalidJson { .. } => "KSRCLI019",
            Self::MissingFields { .. } => "KSRCLI020",
            Self::MissingSections { .. } => "KSRCLI021",
            Self::FieldTypeMismatch { .. } => "KSRCLI022",
            Self::NoResourceKinds { .. } => "KSRCLI030",
            Self::RouteNotFound { .. } => "KSRCLI031",
            Self::GatewayVersionMissing => "KSRCLI032",
            Self::GatewayCrdsMissing => "KSRCLI033",
            Self::KumactlNotFound => "KSRCLI034",
            Self::ReportLineLimit { .. } => "KSRCLI035",
            Self::ReportCodeBlockLimit { .. } => "KSRCLI036",
            Self::AuthoringSessionMissing => "KSRCLI040",
            Self::AuthoringPayloadMissing => "KSRCLI041",
            Self::AuthoringPayloadInvalid { .. } => "KSRCLI042",
            Self::AuthoringShowKindMissing { .. } => "KSRCLI043",
            Self::RunDirExists { .. } => "KSRCLI044",
            Self::AmendmentsRequired { .. } => "KSRCLI045",
            Self::AuthoringValidateFailed { .. } => "KSRCLI046",
            Self::KubectlValidateDecisionRequired => "KSRCLI047",
            Self::KubectlValidateUnavailable => "KSRCLI048",
            Self::TrackedKubectlRequired => "KSRCLI049",
            Self::KubectlTargetOverrideForbidden { .. } => "KSRCLI050",
            Self::UnknownTrackedCluster { .. } => "KSRCLI051",
            Self::NonLocalKubeconfig { .. } => "KSRCLI052",
            Self::RunGroupAlreadyRecorded { .. } => "KSRCLI053",
            Self::RunGroupNotFound { .. } => "KSRCLI054",
            Self::EnvoyConfigTypeNotFound { .. } => "KSRCLI055",
            Self::EnvoyCaptureArgsRequired { .. } => "KSRCLI056",
            Self::EvidenceLabelNotFound { .. } => "KSRCLI057",
            Self::ReportGroupEvidenceRequired => "KSRCLI058",
            Self::UnsafeName { .. } => "KSRCLI059",
            Self::MissingRunStatus => "KSRCLI060",
            Self::GatewayDownloadEmpty { .. } => "KSRCLI061",
            Self::MarkdownShapeMismatch => "KSRCLI999",
            Self::Io { .. } => "IO001",
            Self::Serialize { .. } => "IO002",
            Self::HookPayloadInvalid { .. } => "KSH001",
            Self::WorkflowIo { .. } => "WORKFLOW_IO",
            Self::WorkflowParse { .. } => "WORKFLOW_PARSE",
            Self::WorkflowVersion { .. } => "WORKFLOW_VERSION",
            Self::WorkflowSerialize { .. } => "WORKFLOW_SERIALIZE",
            Self::JsonParse { .. } => "JSON",
            Self::ClusterError { .. } => "CLUSTER",
            Self::UsageError { .. } => "USAGE",
        }
    }

    /// Process exit code for this error kind.
    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::EmptyCommandArgs | Self::MissingTools { .. } | Self::UnsafeName { .. } => 3,
            Self::CommandFailed { .. } => 4,
            Self::MarkdownShapeMismatch => 6,
            Self::Io { .. }
            | Self::Serialize { .. }
            | Self::HookPayloadInvalid { .. }
            | Self::GatewayCrdsMissing
            | Self::ReportLineLimit { .. }
            | Self::ReportCodeBlockLimit { .. }
            | Self::ClusterError { .. }
            | Self::UsageError { .. } => 1,
            _ => 5,
        }
    }

    /// Optional hint for this error kind.
    #[must_use]
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::MissingRunPointer => Some("Run init first.".into()),
            Self::MissingRunContextValue { .. } => {
                Some("Run `harness init` and the required setup step first.".into())
            }
            Self::MissingRunLocation { .. } => {
                Some("Pass `--run-root` or `--run-dir`, or run `harness init` first.".into())
            }
            Self::GatewayDownloadEmpty { .. } => {
                Some("Check the URL and network connectivity.".into())
            }
            Self::KumactlNotFound => Some("Build kumactl first.".into()),
            Self::AuthoringSessionMissing => Some(
                "Run `harness authoring-begin --skill suite-author \
                 --repo-root <path> --feature <name> --mode <interactive|bypass> \
                 --suite-dir <path> --suite-name <name>` first."
                    .into(),
            ),
            Self::AuthoringPayloadMissing => Some(
                "Prefer `--payload <json>` for regular saves. Use `--input <path>` for \
                 file-backed payloads. Pipe JSON to stdin only as a last-resort fallback \
                 when a regular `--payload` argument is not practical."
                    .into(),
            ),
            Self::TrackedKubectlRequired => {
                Some("Run `harness init` and `harness cluster ...` first.".into())
            }
            Self::KubectlTargetOverrideForbidden { .. } => Some(
                "Use `harness run --cluster <name> kubectl ...` for another tracked member.".into(),
            ),
            Self::UnknownTrackedCluster { choices, .. } => Some(format!("Use one of: {choices}.")),
            Self::NonLocalKubeconfig { .. } => Some(
                "Recreate the local cluster with `harness cluster ...` before continuing.".into(),
            ),
            Self::EvidenceLabelNotFound { .. } => Some(
                "Use `harness record --label <label>` or inspect `commands/command-log.md`.".into(),
            ),
            Self::ReportGroupEvidenceRequired => {
                Some("Pass `--evidence-label <label>` or `--evidence <path>`.".into())
            }
            Self::RunDirExists { .. } => Some(
                "Use a new run id or resume the existing run instead of re-running `harness init`."
                    .into(),
            ),
            Self::MissingRunStatus => Some(
                "The run-status.json file could not be loaded. Re-run `harness init` or \
                 check the run directory."
                    .into(),
            ),
            _ => None,
        }
    }

    /// Wrap this error kind with additional detail text.
    #[must_use]
    pub fn with_details(self, details: impl Into<String>) -> CliError {
        CliError {
            kind: self,
            details: Some(details.into()),
        }
    }
}

/// The unified CLI error type, following the `io::Error` pattern.
///
/// Wraps a [`CliErrorKind`] with optional detail text.
#[derive(Debug)]
pub struct CliError {
    kind: CliErrorKind,
    details: Option<String>,
}

impl CliError {
    /// Error code identifying this error.
    #[must_use]
    pub fn code(&self) -> &'static str {
        self.kind.code()
    }

    /// Process exit code for this error.
    #[must_use]
    pub fn exit_code(&self) -> i32 {
        self.kind.exit_code()
    }

    /// Optional hint for this error.
    #[must_use]
    pub fn hint(&self) -> Option<String> {
        self.kind.hint()
    }

    /// Optional detail text.
    #[must_use]
    pub fn details(&self) -> Option<&str> {
        self.details.as_deref()
    }

    /// The underlying error kind.
    #[must_use]
    pub fn kind(&self) -> &CliErrorKind {
        &self.kind
    }

    /// Human-readable error message (without code prefix).
    #[must_use]
    pub fn message(&self) -> String {
        self.kind.to_string()
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code(), self.kind)
    }
}

impl Error for CliError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.kind)
    }
}

impl From<CliErrorKind> for CliError {
    fn from(kind: CliErrorKind) -> Self {
        Self {
            kind,
            details: None,
        }
    }
}

impl From<io::Error> for CliError {
    fn from(e: io::Error) -> Self {
        CliErrorKind::Io {
            detail: format!("IO error: {e}"),
        }
        .into()
    }
}

/// Enum of all hook messages, replacing the static `HookDef` definitions.
///
/// Each variant carries its data as fields. `Display` is derived by thiserror.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum HookMessage {
    // --- Deny ---
    #[error("Run cluster interactions through `harness run` or another `harness` wrapper.")]
    ClusterBinary,

    #[error(
        "Envoy admin calls must go through `harness envoy` or another tracked \
         `harness` wrapper. Prefer one live `harness envoy ...` command over \
         capture-then-read flows."
    )]
    AdminEndpoint,

    #[error("Run closeout is incomplete: missing final state capture.")]
    MissingStateCapture,

    #[error(
        "Run closeout is incomplete: verdict is still pending. \
         Run `harness runner-state --event abort` to mark the run as aborted \
         for clean resume later."
    )]
    VerdictPending,

    #[error("Write path is outside the tracked run surface: {path}")]
    WriteOutsideRun { path: String },

    #[error("Suite-runner state is missing or invalid: {details}")]
    RunnerStateInvalid { details: String },

    #[error("Suite-runner phase or approval is required before {action}: {details}")]
    RunnerFlowRequired { action: String, details: String },

    #[error("Preflight worker reply is invalid: {details}")]
    PreflightReplyInvalid { details: String },

    #[error("Write path is outside the suite-author surface: {path}")]
    WriteOutsideSuite { path: String },

    #[error("Suite-author approval state is missing or invalid: {details}")]
    ApprovalStateInvalid { details: String },

    #[error("Suite-author approval is required before {action}: {details}")]
    ApprovalRequired { action: String, details: String },

    #[error("suite groups must be a list")]
    GroupsNotList,

    #[error("suite baseline_files must be a list")]
    BaselinesNotList,

    #[error("Suite is incomplete or invalid: {details}")]
    SuiteIncomplete { details: String },

    #[error("Suite-author local validator decision is required first: {details}")]
    ValidatorGateRequired { details: String },

    #[error("Suite-author local validator install failed: {details}")]
    ValidatorInstallFailed { details: String },

    #[error("Suite-author local validator gate is not allowed here: {details}")]
    ValidatorGateUnexpected { details: String },

    // --- Warn ---
    #[error("Expected artifact missing after {script}: {target}")]
    MissingArtifact { script: String, target: String },

    #[error("Run `harness preflight` before the first cluster mutation.")]
    RunPreflight,

    #[error("Expected preflight artifacts are missing or incomplete.")]
    PreflightMissing,

    #[error(
        "Suite-author workers must save structured results through \
         `harness authoring-save` and return only a short acknowledgement."
    )]
    CodeReaderFormat,

    #[error("Suite-author worker reply is missing the expected acknowledgement for `{sections}`.")]
    ReaderMissingSections { sections: String },

    #[error(
        "Suite-author worker reply is oversized; save the structured payload \
         and return a short acknowledgement only."
    )]
    ReaderOversizedBlock,

    // --- Info ---
    #[error("Suite-runner runs must stay user-story-first and tracked.")]
    SuiteRunnerTracked,

    #[error("Current run verdict: {verdict}")]
    RunVerdict { verdict: String },

    #[error("Suites must stay user-story-first with concrete variant evidence.")]
    SuiteAuthorTracked,
}

impl HookMessage {
    /// Hook code identifying this message.
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::ClusterBinary | Self::AdminEndpoint => "KSR005",
            Self::MissingArtifact { .. } => "KSR006",
            Self::MissingStateCapture | Self::VerdictPending => "KSR007",
            Self::WriteOutsideRun { .. } => "KSR008",
            Self::RunPreflight => "KSR009",
            Self::PreflightMissing => "KSR010",
            Self::SuiteRunnerTracked => "KSR011",
            Self::RunVerdict { .. } => "KSR012",
            Self::RunnerStateInvalid { .. } => "KSR013",
            Self::RunnerFlowRequired { .. } => "KSR014",
            Self::PreflightReplyInvalid { .. } => "KSR015",
            Self::WriteOutsideSuite { .. } => "KSA001",
            Self::ApprovalStateInvalid { .. } => "KSA002",
            Self::ApprovalRequired { .. } => "KSA003",
            Self::GroupsNotList | Self::BaselinesNotList | Self::SuiteIncomplete { .. } => "KSA004",
            Self::CodeReaderFormat => "KSA006",
            Self::ReaderMissingSections { .. } | Self::ReaderOversizedBlock => "KSA007",
            Self::SuiteAuthorTracked => "KSA008",
            Self::ValidatorGateRequired { .. } => "KSA009",
            Self::ValidatorInstallFailed { .. } => "KSA010",
            Self::ValidatorGateUnexpected { .. } => "KSA011",
        }
    }

    /// Decision for this hook message.
    #[must_use]
    pub fn decision(&self) -> Decision {
        match self {
            Self::ClusterBinary
            | Self::AdminEndpoint
            | Self::MissingStateCapture
            | Self::VerdictPending
            | Self::WriteOutsideRun { .. }
            | Self::RunnerStateInvalid { .. }
            | Self::RunnerFlowRequired { .. }
            | Self::PreflightReplyInvalid { .. }
            | Self::WriteOutsideSuite { .. }
            | Self::ApprovalStateInvalid { .. }
            | Self::ApprovalRequired { .. }
            | Self::GroupsNotList
            | Self::BaselinesNotList
            | Self::SuiteIncomplete { .. }
            | Self::ValidatorGateRequired { .. }
            | Self::ValidatorInstallFailed { .. }
            | Self::ValidatorGateUnexpected { .. } => Decision::Deny,
            Self::MissingArtifact { .. }
            | Self::RunPreflight
            | Self::PreflightMissing
            | Self::CodeReaderFormat
            | Self::ReaderMissingSections { .. }
            | Self::ReaderOversizedBlock => Decision::Warn,
            Self::SuiteRunnerTracked | Self::RunVerdict { .. } | Self::SuiteAuthorTracked => {
                Decision::Info
            }
        }
    }

    /// Convert this message into a [`HookResult`].
    #[must_use]
    pub fn into_result(self) -> HookResult {
        let code = self.code().to_string();
        let message = self.to_string();
        match self.decision() {
            Decision::Deny => HookResult::deny(code, message),
            Decision::Warn => HookResult::warn(code, message),
            _ => HookResult::info(code, message),
        }
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

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    // --- CliError tests ---

    #[test]
    fn cli_err_basic_fields() {
        let err: CliError = CliErrorKind::NotAMapping {
            label: "foo".into(),
        }
        .into();
        assert_eq!(err.code(), "KSRCLI010");
        assert_eq!(err.message(), "foo must be a mapping");
        assert_eq!(err.exit_code(), 5);
        assert!(err.hint().is_none());
    }

    #[test]
    fn cli_err_with_hint() {
        let err: CliError = CliErrorKind::MissingRunPointer.into();
        assert_eq!(err.code(), "KSRCLI005");
        assert_eq!(err.message(), "missing current run pointer");
        assert_eq!(err.hint().as_deref(), Some("Run init first."));
    }

    #[test]
    fn cli_err_with_details_field() {
        let err = CliErrorKind::CommandFailed {
            command: "ls -la".into(),
        }
        .with_details("exit 1");
        assert_eq!(err.code(), "KSRCLI004");
        assert_eq!(err.message(), "command failed: ls -la");
        assert_eq!(err.exit_code(), 4);
        assert_eq!(err.details(), Some("exit 1"));
    }

    #[test]
    fn cli_err_formats_message() {
        let err: CliError = CliErrorKind::MissingFile {
            path: "/tmp/gone.txt".into(),
        }
        .into();
        assert_eq!(err.message(), "missing file: /tmp/gone.txt");
    }

    fn core_error_kinds() -> Vec<CliErrorKind> {
        vec![
            CliErrorKind::EmptyCommandArgs,
            CliErrorKind::MissingTools {
                tools: String::new(),
            },
            CliErrorKind::CommandFailed {
                command: String::new(),
            },
            CliErrorKind::MissingRunPointer,
            CliErrorKind::MissingCloseoutArtifact { rel: String::new() },
            CliErrorKind::MissingStateCapture,
            CliErrorKind::VerdictPending,
            CliErrorKind::MissingRunContextValue {
                field: String::new(),
            },
            CliErrorKind::MissingRunLocation {
                run_id: String::new(),
            },
            CliErrorKind::InvalidJson {
                path: String::new(),
            },
            CliErrorKind::NotAMapping {
                label: String::new(),
            },
            CliErrorKind::NotStringKeys {
                label: String::new(),
            },
            CliErrorKind::NotAList {
                label: String::new(),
            },
            CliErrorKind::NotAllStrings {
                label: String::new(),
            },
            CliErrorKind::MissingFile {
                path: String::new(),
            },
            CliErrorKind::MissingFrontmatter,
            CliErrorKind::UnterminatedFrontmatter,
            CliErrorKind::PathNotFound {
                dotted_path: String::new(),
            },
            CliErrorKind::MissingFields {
                label: String::new(),
                fields: String::new(),
            },
            CliErrorKind::FieldTypeMismatch {
                label: String::new(),
                field: String::new(),
                expected: String::new(),
            },
            CliErrorKind::MissingSections {
                label: String::new(),
                sections: String::new(),
            },
            CliErrorKind::NoResourceKinds {
                manifest: String::new(),
            },
            CliErrorKind::RouteNotFound {
                route_match: String::new(),
            },
            CliErrorKind::GatewayVersionMissing,
            CliErrorKind::GatewayCrdsMissing,
            CliErrorKind::GatewayDownloadEmpty {
                path: String::new(),
            },
            CliErrorKind::KumactlNotFound,
        ]
    }

    fn extended_error_kinds() -> Vec<CliErrorKind> {
        vec![
            CliErrorKind::ReportLineLimit {
                count: String::new(),
                limit: String::new(),
            },
            CliErrorKind::ReportCodeBlockLimit {
                count: String::new(),
                limit: String::new(),
            },
            CliErrorKind::AuthoringSessionMissing,
            CliErrorKind::AuthoringPayloadMissing,
            CliErrorKind::AuthoringPayloadInvalid {
                kind: String::new(),
                details: String::new(),
            },
            CliErrorKind::AuthoringShowKindMissing {
                kind: String::new(),
            },
            CliErrorKind::AuthoringValidateFailed {
                targets: String::new(),
            },
            CliErrorKind::KubectlValidateDecisionRequired,
            CliErrorKind::KubectlValidateUnavailable,
            CliErrorKind::TrackedKubectlRequired,
            CliErrorKind::KubectlTargetOverrideForbidden {
                flag: String::new(),
            },
            CliErrorKind::UnknownTrackedCluster {
                cluster: String::new(),
                choices: String::new(),
            },
            CliErrorKind::NonLocalKubeconfig {
                path: String::new(),
            },
            CliErrorKind::RunGroupAlreadyRecorded {
                group_id: String::new(),
            },
            CliErrorKind::RunGroupNotFound {
                group_id: String::new(),
            },
            CliErrorKind::EnvoyConfigTypeNotFound {
                type_name: String::new(),
            },
            CliErrorKind::EnvoyCaptureArgsRequired {
                fields: String::new(),
            },
            CliErrorKind::EvidenceLabelNotFound {
                label: String::new(),
            },
            CliErrorKind::ReportGroupEvidenceRequired,
            CliErrorKind::AmendmentsRequired {
                path: String::new(),
            },
            CliErrorKind::RunDirExists {
                run_dir: String::new(),
            },
            CliErrorKind::UnsafeName {
                name: String::new(),
            },
            CliErrorKind::MissingRunStatus,
            CliErrorKind::MarkdownShapeMismatch,
            CliErrorKind::Io {
                detail: String::new(),
            },
            CliErrorKind::Serialize {
                detail: String::new(),
            },
            CliErrorKind::HookPayloadInvalid {
                detail: String::new(),
            },
            CliErrorKind::WorkflowIo {
                detail: String::new(),
            },
            CliErrorKind::WorkflowParse {
                detail: String::new(),
            },
            CliErrorKind::WorkflowVersion {
                detail: String::new(),
            },
            CliErrorKind::WorkflowSerialize {
                detail: String::new(),
            },
            CliErrorKind::JsonParse {
                detail: String::new(),
            },
            CliErrorKind::ClusterError {
                detail: String::new(),
            },
            CliErrorKind::UsageError {
                detail: String::new(),
            },
        ]
    }

    #[test]
    fn cli_err_all_codes_unique() {
        let mut all_kinds = core_error_kinds();
        all_kinds.extend(extended_error_kinds());
        let codes: Vec<&str> = all_kinds.iter().map(CliErrorKind::code).collect();
        let unique: HashSet<&str> = codes.iter().copied().collect();
        assert_eq!(codes.len(), unique.len(), "duplicate error codes found");
    }

    #[test]
    fn cli_err_no_args_message() {
        let err: CliError = CliErrorKind::MissingFrontmatter.into();
        assert_eq!(err.message(), "missing YAML frontmatter");
    }

    #[test]
    fn cli_err_hint_formats_correctly() {
        let err: CliError = CliErrorKind::KumactlNotFound.into();
        assert_eq!(err.hint().as_deref(), Some("Build kumactl first."));
    }

    #[test]
    fn cli_err_report_line_limit() {
        let err: CliError = CliErrorKind::ReportLineLimit {
            count: "500".into(),
            limit: "400".into(),
        }
        .into();
        assert_eq!(err.message(), "report exceeds line limit: 500>400");
        assert_eq!(err.exit_code(), 1);
    }

    #[test]
    fn cli_err_closeout_codes_are_distinct() {
        let codes: HashSet<&str> = [
            CliErrorKind::MissingCloseoutArtifact { rel: String::new() }.code(),
            CliErrorKind::MissingStateCapture.code(),
            CliErrorKind::VerdictPending.code(),
        ]
        .into_iter()
        .collect();
        assert_eq!(codes.len(), 3);
    }

    #[test]
    fn cli_err_markdown_shape_mismatch() {
        let err: CliError = CliErrorKind::MarkdownShapeMismatch.into();
        assert_eq!(err.code(), "KSRCLI999");
        assert_eq!(err.exit_code(), 6);
    }

    #[test]
    fn cli_err_display_trait() {
        let err: CliError = CliErrorKind::MissingTools {
            tools: "kubectl".into(),
        }
        .into();
        let displayed = format!("{err}");
        assert_eq!(displayed, "[KSRCLI002] missing required tools: kubectl");
    }

    #[test]
    fn render_error_includes_hint_and_details() {
        let err = CliErrorKind::MissingRunPointer.with_details("stack");
        let rendered = render_error(&err);
        assert!(rendered.contains("ERROR [KSRCLI005] missing current run pointer"));
        assert!(rendered.contains("Hint: Run init first."));
        assert!(rendered.contains("stack"));
    }

    #[test]
    fn render_error_without_hint_or_details() {
        let err: CliError = CliErrorKind::Io {
            detail: "oops".into(),
        }
        .into();
        let rendered = render_error(&err);
        assert!(rendered.contains("ERROR [IO001] oops"));
        assert!(!rendered.contains("Hint:"));
        assert!(!rendered.contains("Details:"));
    }

    // --- HookMessage tests ---

    #[test]
    fn hook_msg_deny_result() {
        let result = HookMessage::ClusterBinary.into_result();
        assert_eq!(result.decision, Decision::Deny);
        assert_eq!(result.code, "KSR005");
        assert!(result.message.contains("`harness run`"));
    }

    #[test]
    fn hook_msg_warn_result() {
        let result = HookMessage::MissingArtifact {
            script: "preflight.py".into(),
            target: "/tmp/x".into(),
        }
        .into_result();
        assert_eq!(result.decision, Decision::Warn);
        assert_eq!(result.code, "KSR006");
        assert!(result.message.contains("preflight.py"));
        assert!(result.message.contains("/tmp/x"));
    }

    #[test]
    fn hook_msg_info_result() {
        let result = HookMessage::RunVerdict {
            verdict: "pass".into(),
        }
        .into_result();
        assert_eq!(result.decision, Decision::Info);
        assert_eq!(result.code, "KSR012");
        assert!(result.message.contains("pass"));
    }

    #[test]
    fn hook_msg_deny_with_fields() {
        let result = HookMessage::WriteOutsideRun {
            path: "/bad/path".into(),
        }
        .into_result();
        assert_eq!(result.decision, Decision::Deny);
        assert!(result.message.contains("/bad/path"));
    }

    #[test]
    fn hook_msg_no_fields_message() {
        let result = HookMessage::GroupsNotList.into_result();
        assert_eq!(result.message, "suite groups must be a list");
    }

    #[test]
    fn hook_message_count() {
        let all_hooks: Vec<HookMessage> = vec![
            HookMessage::ClusterBinary,
            HookMessage::AdminEndpoint,
            HookMessage::MissingStateCapture,
            HookMessage::VerdictPending,
            HookMessage::WriteOutsideRun {
                path: String::new(),
            },
            HookMessage::RunnerStateInvalid {
                details: String::new(),
            },
            HookMessage::RunnerFlowRequired {
                action: String::new(),
                details: String::new(),
            },
            HookMessage::PreflightReplyInvalid {
                details: String::new(),
            },
            HookMessage::WriteOutsideSuite {
                path: String::new(),
            },
            HookMessage::ApprovalStateInvalid {
                details: String::new(),
            },
            HookMessage::ApprovalRequired {
                action: String::new(),
                details: String::new(),
            },
            HookMessage::GroupsNotList,
            HookMessage::BaselinesNotList,
            HookMessage::SuiteIncomplete {
                details: String::new(),
            },
            HookMessage::ValidatorGateRequired {
                details: String::new(),
            },
            HookMessage::ValidatorInstallFailed {
                details: String::new(),
            },
            HookMessage::ValidatorGateUnexpected {
                details: String::new(),
            },
            HookMessage::MissingArtifact {
                script: String::new(),
                target: String::new(),
            },
            HookMessage::RunPreflight,
            HookMessage::PreflightMissing,
            HookMessage::CodeReaderFormat,
            HookMessage::ReaderMissingSections {
                sections: String::new(),
            },
            HookMessage::ReaderOversizedBlock,
            HookMessage::SuiteRunnerTracked,
            HookMessage::RunVerdict {
                verdict: String::new(),
            },
            HookMessage::SuiteAuthorTracked,
        ];
        assert_eq!(all_hooks.len(), 26);
    }
}
