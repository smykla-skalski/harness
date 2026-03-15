use std::borrow::Cow;
use std::error::Error;
use std::fmt;
use std::io;

use crate::hook::{Decision, HookResult};

/// Build a `Cow<'static, str>` from a `format!`-style expression.
///
/// Produces `Cow::Owned(format!(...))` so the caller never needs a
/// trailing `.into()`.
macro_rules! cow {
    ($($arg:tt)*) => {
        ::std::borrow::Cow::Owned(format!($($arg)*))
    };
}

pub(crate) use cow;

/// Macro that co-locates each `CliErrorKind` variant with its error code,
/// display message, and optional exit code. Generates the enum, `code()`,
/// and `exit_code()` in one place.
macro_rules! define_cli_errors {
    (
        $(
            $variant:ident $({ $($field:ident : $type:ty),* $(,)? })?
            => {
                code: $code:literal,
                msg: $msg:literal
                $(, exit: $exit:expr)?
            }
        ),* $(,)?
    ) => {
        #[derive(Debug, thiserror::Error)]
        #[non_exhaustive]
        pub enum CliErrorKind {
            $(
                #[error($msg)]
                $variant $({ $($field: $type),* })?,
            )*
        }

        impl CliErrorKind {
            #[must_use]
            pub fn code(&self) -> &'static str {
                match self {
                    $(Self::$variant { .. } => $code,)*
                }
            }

            #[must_use]
            pub fn exit_code(&self) -> i32 {
                match self {
                    $(Self::$variant { .. } => define_cli_errors!(@exit $($exit)?),)*
                }
            }
        }
    };

    (@exit) => { 5 };
    (@exit $exit:expr) => { $exit };
}

define_cli_errors! {
    // --- Input validation (exit 3) ---
    EmptyCommandArgs => {
        code: "KSRCLI001",
        msg: "command args must not be empty",
        exit: 3
    },
    MissingTools { tools: Cow<'static, str> } => {
        code: "KSRCLI002",
        msg: "missing required tools: {tools}",
        exit: 3
    },
    UnsafeName { name: Cow<'static, str> } => {
        code: "KSRCLI059",
        msg: "unsafe name: {name} (must not contain path separators or \"..\")",
        exit: 3
    },

    // --- Command execution (exit 4) ---
    CommandFailed { command: Cow<'static, str> } => {
        code: "KSRCLI004",
        msg: "command failed: {command}",
        exit: 4
    },

    // --- Run lifecycle (exit 5 = default) ---
    MissingRunPointer => {
        code: "KSRCLI005",
        msg: "missing current run pointer"
    },
    MissingCloseoutArtifact { rel: Cow<'static, str> } => {
        code: "KSRCLI006",
        msg: "missing required closeout artifact: {rel}"
    },
    MissingStateCapture => {
        code: "KSRCLI007",
        msg: "run is missing a final state capture"
    },
    VerdictPending => {
        code: "KSRCLI008",
        msg: "run overall verdict is still pending"
    },
    MissingRunContextValue { field: Cow<'static, str> } => {
        code: "KSRCLI009",
        msg: "missing run context value: {field}"
    },
    MissingRunLocation { run_id: Cow<'static, str> } => {
        code: "KSRCLI018",
        msg: "missing explicit run location for run id: {run_id}"
    },
    RunDirExists { run_dir: Cow<'static, str> } => {
        code: "KSRCLI044",
        msg: "run directory already exists: {run_dir}"
    },
    MissingRunStatus => {
        code: "KSRCLI060",
        msg: "run has no recorded status"
    },
    RunGroupAlreadyRecorded { group_id: Cow<'static, str> } => {
        code: "KSRCLI053",
        msg: "run group is already recorded: {group_id}"
    },
    RunGroupNotFound { group_id: Cow<'static, str> } => {
        code: "KSRCLI054",
        msg: "group is not present in the run plan: {group_id}"
    },

    // --- File/path errors (exit 5 = default) ---
    MissingFile { path: Cow<'static, str> } => {
        code: "KSRCLI014",
        msg: "missing file: {path}"
    },
    InvalidJson { path: Cow<'static, str> } => {
        code: "KSRCLI019",
        msg: "invalid JSON in {path}"
    },
    PathNotFound { dotted_path: Cow<'static, str> } => {
        code: "KSRCLI017",
        msg: "path not found: {dotted_path}"
    },

    // --- Schema/structure validation (exit 5 = default) ---
    NotAMapping { label: Cow<'static, str> } => {
        code: "KSRCLI010",
        msg: "{label} must be a mapping"
    },
    NotStringKeys { label: Cow<'static, str> } => {
        code: "KSRCLI011",
        msg: "{label} must use string keys"
    },
    NotAList { label: Cow<'static, str> } => {
        code: "KSRCLI012",
        msg: "{label} must be a list"
    },
    NotAllStrings { label: Cow<'static, str> } => {
        code: "KSRCLI013",
        msg: "{label} must contain only strings"
    },
    MissingFrontmatter => {
        code: "KSRCLI015",
        msg: "missing YAML frontmatter"
    },
    UnterminatedFrontmatter => {
        code: "KSRCLI016",
        msg: "unterminated YAML frontmatter"
    },
    MissingFields { label: Cow<'static, str>, fields: Cow<'static, str> } => {
        code: "KSRCLI020",
        msg: "missing required fields: {label}: {fields}"
    },
    FieldTypeMismatch {
        label: Cow<'static, str>,
        field: Cow<'static, str>,
        expected: Cow<'static, str>,
    } => {
        code: "KSRCLI022",
        msg: "field type mismatch in {label}: {field} (expected {expected})"
    },
    MissingSections { label: Cow<'static, str>, sections: Cow<'static, str> } => {
        code: "KSRCLI021",
        msg: "missing sections: {label}: {sections}"
    },
    MarkdownShapeMismatch => {
        code: "KSRCLI999",
        msg: "markdown row shape mismatch",
        exit: 6
    },

    // --- Gateway ---
    GatewayVersionMissing => {
        code: "KSRCLI032",
        msg: "unable to resolve Gateway API version from go.mod"
    },
    GatewayCrdsMissing => {
        code: "KSRCLI033",
        msg: "Gateway API CRDs are not installed",
        exit: 1
    },
    GatewayDownloadEmpty { path: Cow<'static, str> } => {
        code: "KSRCLI061",
        msg: "downloaded Gateway API manifest is empty: {path}"
    },

    // --- Kubernetes/cluster ---
    NoResourceKinds { manifest: Cow<'static, str> } => {
        code: "KSRCLI030",
        msg: "no resource kinds found in {manifest}"
    },
    RouteNotFound { route_match: Cow<'static, str> } => {
        code: "KSRCLI031",
        msg: "route {route_match} not found"
    },
    KumactlNotFound => {
        code: "KSRCLI034",
        msg: "unable to find local kumactl"
    },
    TrackedKubectlRequired => {
        code: "KSRCLI049",
        msg: "tracked kubectl command requires an active local cluster kubeconfig"
    },
    KubectlTargetOverrideForbidden { flag: Cow<'static, str> } => {
        code: "KSRCLI050",
        msg: "kubectl target override is not allowed in tracked runs: {flag}"
    },
    UnknownTrackedCluster { cluster: Cow<'static, str>, choices: Cow<'static, str> } => {
        code: "KSRCLI051",
        msg: "unknown tracked cluster member: {cluster}"
    },
    NonLocalKubeconfig { path: Cow<'static, str> } => {
        code: "KSRCLI052",
        msg: "tracked kubeconfig is not a local harness cluster: {path}"
    },

    // --- Envoy ---
    EnvoyConfigTypeNotFound { type_name: Cow<'static, str> } => {
        code: "KSRCLI055",
        msg: "envoy config type not found: {type_name}"
    },
    EnvoyCaptureArgsRequired { fields: Cow<'static, str> } => {
        code: "KSRCLI056",
        msg: "envoy live capture requires: {fields}"
    },

    // --- Report (exit 1) ---
    ReportLineLimit { count: Cow<'static, str>, limit: Cow<'static, str> } => {
        code: "KSRCLI035",
        msg: "report exceeds line limit: {count}>{limit}",
        exit: 1
    },
    ReportCodeBlockLimit { count: Cow<'static, str>, limit: Cow<'static, str> } => {
        code: "KSRCLI036",
        msg: "report exceeds code block limit: {count}>{limit}",
        exit: 1
    },
    EvidenceLabelNotFound { label: Cow<'static, str> } => {
        code: "KSRCLI057",
        msg: "no recorded artifact found for evidence label: {label}"
    },
    ReportGroupEvidenceRequired => {
        code: "KSRCLI058",
        msg: "group report requires at least one evidence input"
    },

    // --- Authoring ---
    AuthoringSessionMissing => {
        code: "KSRCLI040",
        msg: "missing active suite:new authoring session"
    },
    AuthoringPayloadMissing => {
        code: "KSRCLI041",
        msg: "missing suite:new payload input"
    },
    AuthoringPayloadInvalid { kind: Cow<'static, str>, details: Cow<'static, str> } => {
        code: "KSRCLI042",
        msg: "invalid suite:new {kind} payload: {details}"
    },
    AuthoringShowKindMissing { kind: Cow<'static, str> } => {
        code: "KSRCLI043",
        msg: "missing saved suite:new payload: {kind}"
    },
    AmendmentsRequired { path: Cow<'static, str> } => {
        code: "KSRCLI045",
        msg: "suite amendments entry is missing or empty: {path}"
    },
    AuthoringValidateFailed { targets: Cow<'static, str> } => {
        code: "KSRCLI046",
        msg: "suite:new manifest validation failed: {targets}"
    },
    KubectlValidateDecisionRequired => {
        code: "KSRCLI047",
        msg: "suite:new local validator decision is still required"
    },
    KubectlValidateUnavailable => {
        code: "KSRCLI048",
        msg: "suite:new local validator is unavailable"
    },

    // --- Universal/container errors (exit 4) ---
    ContainerStartFailed { name: Cow<'static, str> } => {
        code: "KSRCLI070",
        msg: "container start failed: {name}",
        exit: 4
    },
    ContainerNotFound { name: Cow<'static, str> } => {
        code: "KSRCLI071",
        msg: "container not found: {name}",
        exit: 4
    },
    CpApiUnreachable { url: Cow<'static, str> } => {
        code: "KSRCLI072",
        msg: "control plane API unreachable: {url}",
        exit: 4
    },
    TokenGenerationFailed { details: Cow<'static, str> } => {
        code: "KSRCLI073",
        msg: "dataplane token generation failed: {details}",
        exit: 4
    },
    DockerNetworkFailed { name: Cow<'static, str> } => {
        code: "KSRCLI074",
        msg: "docker network operation failed: {name}",
        exit: 4
    },
    ComposeFileFailed { path: Cow<'static, str> } => {
        code: "KSRCLI075",
        msg: "docker compose operation failed: {path}",
        exit: 4
    },
    ImageBuildFailed { target: Cow<'static, str> } => {
        code: "KSRCLI076",
        msg: "image build failed: {target}",
        exit: 4
    },
    TemplateRender { detail: Cow<'static, str> } => {
        code: "KSRCLI077",
        msg: "template render failed: {detail}",
        exit: 4
    },

    // --- IO/serialization (exit 1) ---
    Io { detail: Cow<'static, str> } => {
        code: "IO001",
        msg: "{detail}",
        exit: 1
    },
    Serialize { detail: Cow<'static, str> } => {
        code: "IO002",
        msg: "serialization failed: {detail}",
        exit: 1
    },
    HookPayloadInvalid { detail: Cow<'static, str> } => {
        code: "KSH001",
        msg: "{detail}",
        exit: 1
    },
    ClusterError { detail: Cow<'static, str> } => {
        code: "CLUSTER",
        msg: "{detail}",
        exit: 1
    },
    UsageError { detail: Cow<'static, str> } => {
        code: "USAGE",
        msg: "{detail}",
        exit: 1
    },

    // --- Workflow (exit 5 = default) ---
    WorkflowIo { detail: Cow<'static, str> } => {
        code: "WORKFLOW_IO",
        msg: "{detail}"
    },
    WorkflowParse { detail: Cow<'static, str> } => {
        code: "WORKFLOW_PARSE",
        msg: "{detail}"
    },
    WorkflowVersion { detail: Cow<'static, str> } => {
        code: "WORKFLOW_VERSION",
        msg: "unsupported workflow schema version: {detail}"
    },
    WorkflowSerialize { detail: Cow<'static, str> } => {
        code: "WORKFLOW_SERIALIZE",
        msg: "serialization failed: {detail}"
    },
    JsonParse { detail: Cow<'static, str> } => {
        code: "JSON",
        msg: "{detail}"
    },
}

// --- CliErrorKind constructors ---

macro_rules! cli_constructor {
    ($fn_name:ident, $Variant:ident, $($field:ident),+) => {
        pub fn $fn_name($($field: impl Into<Cow<'static, str>>),+) -> Self {
            Self::$Variant { $($field: $field.into()),+ }
        }
    };
}

impl CliErrorKind {
    cli_constructor!(missing_tools, MissingTools, tools);
    cli_constructor!(unsafe_name, UnsafeName, name);
    cli_constructor!(command_failed, CommandFailed, command);
    cli_constructor!(missing_closeout_artifact, MissingCloseoutArtifact, rel);
    cli_constructor!(missing_run_context_value, MissingRunContextValue, field);
    cli_constructor!(missing_run_location, MissingRunLocation, run_id);
    cli_constructor!(run_dir_exists, RunDirExists, run_dir);
    cli_constructor!(
        run_group_already_recorded,
        RunGroupAlreadyRecorded,
        group_id
    );
    cli_constructor!(run_group_not_found, RunGroupNotFound, group_id);
    cli_constructor!(missing_file, MissingFile, path);
    cli_constructor!(invalid_json, InvalidJson, path);
    cli_constructor!(path_not_found, PathNotFound, dotted_path);
    cli_constructor!(not_a_mapping, NotAMapping, label);
    cli_constructor!(not_string_keys, NotStringKeys, label);
    cli_constructor!(not_a_list, NotAList, label);
    cli_constructor!(not_all_strings, NotAllStrings, label);
    cli_constructor!(missing_fields, MissingFields, label, fields);
    cli_constructor!(
        field_type_mismatch,
        FieldTypeMismatch,
        label,
        field,
        expected
    );
    cli_constructor!(missing_sections, MissingSections, label, sections);
    cli_constructor!(gateway_download_empty, GatewayDownloadEmpty, path);
    cli_constructor!(no_resource_kinds, NoResourceKinds, manifest);
    cli_constructor!(route_not_found, RouteNotFound, route_match);
    cli_constructor!(
        kubectl_target_override_forbidden,
        KubectlTargetOverrideForbidden,
        flag
    );
    cli_constructor!(
        unknown_tracked_cluster,
        UnknownTrackedCluster,
        cluster,
        choices
    );
    cli_constructor!(non_local_kubeconfig, NonLocalKubeconfig, path);
    cli_constructor!(
        envoy_config_type_not_found,
        EnvoyConfigTypeNotFound,
        type_name
    );
    cli_constructor!(
        envoy_capture_args_required,
        EnvoyCaptureArgsRequired,
        fields
    );
    cli_constructor!(report_line_limit, ReportLineLimit, count, limit);
    cli_constructor!(report_code_block_limit, ReportCodeBlockLimit, count, limit);
    cli_constructor!(evidence_label_not_found, EvidenceLabelNotFound, label);
    cli_constructor!(
        authoring_payload_invalid,
        AuthoringPayloadInvalid,
        kind,
        details
    );
    cli_constructor!(authoring_show_kind_missing, AuthoringShowKindMissing, kind);
    cli_constructor!(amendments_required, AmendmentsRequired, path);
    cli_constructor!(authoring_validate_failed, AuthoringValidateFailed, targets);
    cli_constructor!(container_start_failed, ContainerStartFailed, name);
    cli_constructor!(container_not_found, ContainerNotFound, name);
    cli_constructor!(cp_api_unreachable, CpApiUnreachable, url);
    cli_constructor!(token_generation_failed, TokenGenerationFailed, details);
    cli_constructor!(docker_network_failed, DockerNetworkFailed, name);
    cli_constructor!(compose_file_failed, ComposeFileFailed, path);
    cli_constructor!(image_build_failed, ImageBuildFailed, target);
    cli_constructor!(template_render, TemplateRender, detail);
    cli_constructor!(io, Io, detail);
    cli_constructor!(serialize, Serialize, detail);
    cli_constructor!(hook_payload_invalid, HookPayloadInvalid, detail);
    cli_constructor!(cluster_error, ClusterError, detail);
    cli_constructor!(usage_error, UsageError, detail);
    cli_constructor!(workflow_io, WorkflowIo, detail);
    cli_constructor!(workflow_parse, WorkflowParse, detail);
    cli_constructor!(workflow_version, WorkflowVersion, detail);
    cli_constructor!(workflow_serialize, WorkflowSerialize, detail);
    cli_constructor!(json_parse, JsonParse, detail);
}

impl CliErrorKind {
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
                "Run `harness authoring-begin --skill suite:new \
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
        CliErrorKind::io(cow!("IO error: {e}")).into()
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
    WriteOutsideRun { path: Cow<'static, str> },

    #[error("Suite:run state is missing or invalid: {details}")]
    RunnerStateInvalid { details: Cow<'static, str> },

    #[error("Suite:run phase or approval is required before {action}: {details}")]
    RunnerFlowRequired {
        action: Cow<'static, str>,
        details: Cow<'static, str>,
    },

    #[error("Preflight worker reply is invalid: {details}")]
    PreflightReplyInvalid { details: Cow<'static, str> },

    #[error("Write path is outside the suite:new surface: {path}")]
    WriteOutsideSuite { path: Cow<'static, str> },

    #[error("Suite:new approval state is missing or invalid: {details}")]
    ApprovalStateInvalid { details: Cow<'static, str> },

    #[error("Suite:new approval is required before {action}: {details}")]
    ApprovalRequired {
        action: Cow<'static, str>,
        details: Cow<'static, str>,
    },

    #[error("suite groups must be a list")]
    GroupsNotList,

    #[error("suite baseline_files must be a list")]
    BaselinesNotList,

    #[error("Suite is incomplete or invalid: {details}")]
    SuiteIncomplete { details: Cow<'static, str> },

    #[error("Suite:new local validator decision is required first: {details}")]
    ValidatorGateRequired { details: Cow<'static, str> },

    #[error("Suite:new local validator install failed: {details}")]
    ValidatorInstallFailed { details: Cow<'static, str> },

    #[error("Suite:new local validator gate is not allowed here: {details}")]
    ValidatorGateUnexpected { details: Cow<'static, str> },

    // --- Warn ---
    #[error("Expected artifact missing after {script}: {target}")]
    MissingArtifact {
        script: Cow<'static, str>,
        target: Cow<'static, str>,
    },

    #[error("Run `harness preflight` before the first cluster mutation.")]
    RunPreflight,

    #[error("Expected preflight artifacts are missing or incomplete.")]
    PreflightMissing,

    #[error(
        "Suite:new workers must save structured results through \
         `harness authoring-save` and return only a short acknowledgement."
    )]
    CodeReaderFormat,

    #[error("Suite:new worker reply is missing the expected acknowledgement for `{sections}`.")]
    ReaderMissingSections { sections: Cow<'static, str> },

    #[error(
        "Suite:new worker reply is oversized; save the structured payload \
         and return a short acknowledgement only."
    )]
    ReaderOversizedBlock,

    // --- Info ---
    #[error("Suite:run runs must stay user-story-first and tracked.")]
    SuiteRunnerTracked,

    #[error("Current run verdict: {verdict}")]
    RunVerdict { verdict: Cow<'static, str> },

    #[error("Suites must stay user-story-first with concrete variant evidence.")]
    SuiteAuthorTracked,
}

// --- HookMessage constructors ---

impl HookMessage {
    pub fn write_outside_run(path: impl Into<Cow<'static, str>>) -> Self {
        Self::WriteOutsideRun { path: path.into() }
    }
    pub fn runner_state_invalid(details: impl Into<Cow<'static, str>>) -> Self {
        Self::RunnerStateInvalid {
            details: details.into(),
        }
    }
    pub fn runner_flow_required(
        action: impl Into<Cow<'static, str>>,
        details: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::RunnerFlowRequired {
            action: action.into(),
            details: details.into(),
        }
    }
    pub fn preflight_reply_invalid(details: impl Into<Cow<'static, str>>) -> Self {
        Self::PreflightReplyInvalid {
            details: details.into(),
        }
    }
    pub fn write_outside_suite(path: impl Into<Cow<'static, str>>) -> Self {
        Self::WriteOutsideSuite { path: path.into() }
    }
    pub fn approval_state_invalid(details: impl Into<Cow<'static, str>>) -> Self {
        Self::ApprovalStateInvalid {
            details: details.into(),
        }
    }
    pub fn approval_required(
        action: impl Into<Cow<'static, str>>,
        details: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::ApprovalRequired {
            action: action.into(),
            details: details.into(),
        }
    }
    pub fn suite_incomplete(details: impl Into<Cow<'static, str>>) -> Self {
        Self::SuiteIncomplete {
            details: details.into(),
        }
    }
    pub fn validator_gate_required(details: impl Into<Cow<'static, str>>) -> Self {
        Self::ValidatorGateRequired {
            details: details.into(),
        }
    }
    pub fn validator_install_failed(details: impl Into<Cow<'static, str>>) -> Self {
        Self::ValidatorInstallFailed {
            details: details.into(),
        }
    }
    pub fn validator_gate_unexpected(details: impl Into<Cow<'static, str>>) -> Self {
        Self::ValidatorGateUnexpected {
            details: details.into(),
        }
    }
    pub fn missing_artifact(
        script: impl Into<Cow<'static, str>>,
        target: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::MissingArtifact {
            script: script.into(),
            target: target.into(),
        }
    }
    pub fn reader_missing_sections(sections: impl Into<Cow<'static, str>>) -> Self {
        Self::ReaderMissingSections {
            sections: sections.into(),
        }
    }
    pub fn run_verdict(verdict: impl Into<Cow<'static, str>>) -> Self {
        Self::RunVerdict {
            verdict: verdict.into(),
        }
    }
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
        let err: CliError = CliErrorKind::not_a_mapping("foo").into();
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
        let err = CliErrorKind::command_failed("ls -la").with_details("exit 1");
        assert_eq!(err.code(), "KSRCLI004");
        assert_eq!(err.message(), "command failed: ls -la");
        assert_eq!(err.exit_code(), 4);
        assert_eq!(err.details(), Some("exit 1"));
    }

    #[test]
    fn cli_err_formats_message() {
        let err: CliError = CliErrorKind::missing_file("/tmp/gone.txt").into();
        assert_eq!(err.message(), "missing file: /tmp/gone.txt");
    }

    fn core_error_kinds() -> Vec<CliErrorKind> {
        vec![
            CliErrorKind::EmptyCommandArgs,
            CliErrorKind::missing_tools(""),
            CliErrorKind::command_failed(""),
            CliErrorKind::MissingRunPointer,
            CliErrorKind::missing_closeout_artifact(""),
            CliErrorKind::MissingStateCapture,
            CliErrorKind::VerdictPending,
            CliErrorKind::missing_run_context_value(""),
            CliErrorKind::missing_run_location(""),
            CliErrorKind::invalid_json(""),
            CliErrorKind::not_a_mapping(""),
            CliErrorKind::not_string_keys(""),
            CliErrorKind::not_a_list(""),
            CliErrorKind::not_all_strings(""),
            CliErrorKind::missing_file(""),
            CliErrorKind::MissingFrontmatter,
            CliErrorKind::UnterminatedFrontmatter,
            CliErrorKind::path_not_found(""),
            CliErrorKind::missing_fields("", ""),
            CliErrorKind::field_type_mismatch("", "", ""),
            CliErrorKind::missing_sections("", ""),
            CliErrorKind::no_resource_kinds(""),
            CliErrorKind::route_not_found(""),
            CliErrorKind::GatewayVersionMissing,
            CliErrorKind::GatewayCrdsMissing,
            CliErrorKind::gateway_download_empty(""),
            CliErrorKind::KumactlNotFound,
        ]
    }

    fn extended_error_kinds() -> Vec<CliErrorKind> {
        vec![
            CliErrorKind::report_line_limit("", ""),
            CliErrorKind::report_code_block_limit("", ""),
            CliErrorKind::AuthoringSessionMissing,
            CliErrorKind::AuthoringPayloadMissing,
            CliErrorKind::authoring_payload_invalid("", ""),
            CliErrorKind::authoring_show_kind_missing(""),
            CliErrorKind::authoring_validate_failed(""),
            CliErrorKind::KubectlValidateDecisionRequired,
            CliErrorKind::KubectlValidateUnavailable,
            CliErrorKind::TrackedKubectlRequired,
            CliErrorKind::kubectl_target_override_forbidden(""),
            CliErrorKind::unknown_tracked_cluster("", ""),
            CliErrorKind::non_local_kubeconfig(""),
            CliErrorKind::run_group_already_recorded(""),
            CliErrorKind::run_group_not_found(""),
            CliErrorKind::envoy_config_type_not_found(""),
            CliErrorKind::envoy_capture_args_required(""),
            CliErrorKind::evidence_label_not_found(""),
            CliErrorKind::ReportGroupEvidenceRequired,
            CliErrorKind::amendments_required(""),
            CliErrorKind::run_dir_exists(""),
            CliErrorKind::unsafe_name(""),
            CliErrorKind::MissingRunStatus,
            CliErrorKind::MarkdownShapeMismatch,
            CliErrorKind::container_start_failed(""),
            CliErrorKind::container_not_found(""),
            CliErrorKind::cp_api_unreachable(""),
            CliErrorKind::token_generation_failed(""),
            CliErrorKind::docker_network_failed(""),
            CliErrorKind::compose_file_failed(""),
            CliErrorKind::image_build_failed(""),
            CliErrorKind::template_render(""),
            CliErrorKind::io(""),
            CliErrorKind::serialize(""),
            CliErrorKind::hook_payload_invalid(""),
            CliErrorKind::workflow_io(""),
            CliErrorKind::workflow_parse(""),
            CliErrorKind::workflow_version(""),
            CliErrorKind::workflow_serialize(""),
            CliErrorKind::json_parse(""),
            CliErrorKind::cluster_error(""),
            CliErrorKind::usage_error(""),
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
        let err: CliError = CliErrorKind::report_line_limit("500", "400").into();
        assert_eq!(err.message(), "report exceeds line limit: 500>400");
        assert_eq!(err.exit_code(), 1);
    }

    #[test]
    fn cli_err_closeout_codes_are_distinct() {
        let codes: HashSet<&str> = [
            CliErrorKind::missing_closeout_artifact("").code(),
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
        let err: CliError = CliErrorKind::missing_tools("kubectl").into();
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
        let err: CliError = CliErrorKind::io("oops").into();
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
        let result = HookMessage::missing_artifact("preflight.py", "/tmp/x").into_result();
        assert_eq!(result.decision, Decision::Warn);
        assert_eq!(result.code, "KSR006");
        assert!(result.message.contains("preflight.py"));
        assert!(result.message.contains("/tmp/x"));
    }

    #[test]
    fn hook_msg_info_result() {
        let result = HookMessage::run_verdict("pass").into_result();
        assert_eq!(result.decision, Decision::Info);
        assert_eq!(result.code, "KSR012");
        assert!(result.message.contains("pass"));
    }

    #[test]
    fn hook_msg_deny_with_fields() {
        let result = HookMessage::write_outside_run("/bad/path").into_result();
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
            HookMessage::write_outside_run(""),
            HookMessage::runner_state_invalid(""),
            HookMessage::runner_flow_required("", ""),
            HookMessage::preflight_reply_invalid(""),
            HookMessage::write_outside_suite(""),
            HookMessage::approval_state_invalid(""),
            HookMessage::approval_required("", ""),
            HookMessage::GroupsNotList,
            HookMessage::BaselinesNotList,
            HookMessage::suite_incomplete(""),
            HookMessage::validator_gate_required(""),
            HookMessage::validator_install_failed(""),
            HookMessage::validator_gate_unexpected(""),
            HookMessage::missing_artifact("", ""),
            HookMessage::RunPreflight,
            HookMessage::PreflightMissing,
            HookMessage::CodeReaderFormat,
            HookMessage::reader_missing_sections(""),
            HookMessage::ReaderOversizedBlock,
            HookMessage::SuiteRunnerTracked,
            HookMessage::run_verdict(""),
            HookMessage::SuiteAuthorTracked,
        ];
        assert_eq!(all_hooks.len(), 26);
    }
}
