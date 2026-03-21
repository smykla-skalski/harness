use std::borrow::Cow;

mod constructors;
mod hints;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum RunSetupError {
    #[error("missing current run pointer")]
    MissingRunPointer,
    #[error("missing required closeout artifact: {rel}")]
    MissingCloseoutArtifact { rel: Cow<'static, str> },
    #[error("run is missing a final state capture")]
    MissingStateCapture,
    #[error("run overall verdict is still pending")]
    VerdictPending,
    #[error("missing run context value: {field}")]
    MissingRunContextValue { field: Cow<'static, str> },
    #[error("missing explicit run location for run id: {run_id}")]
    MissingRunLocation { run_id: Cow<'static, str> },
    #[error("run directory already exists: {run_dir}")]
    RunDirExists { run_dir: Cow<'static, str> },
    #[error("run has no recorded status")]
    MissingRunStatus,
    #[error("run group is already recorded: {group_id}")]
    RunGroupAlreadyRecorded { group_id: Cow<'static, str> },
    #[error("group is not present in the run plan: {group_id}")]
    RunGroupNotFound { group_id: Cow<'static, str> },
    #[error("unable to resolve Gateway API version from go.mod")]
    GatewayVersionMissing,
    #[error("Gateway API CRDs are not installed")]
    GatewayCrdsMissing,
    #[error("downloaded Gateway API manifest is empty: {path}")]
    GatewayDownloadEmpty { path: Cow<'static, str> },
    #[error("no resource kinds found in {manifest}")]
    NoResourceKinds { manifest: Cow<'static, str> },
    #[error("route {route_match} not found")]
    RouteNotFound { route_match: Cow<'static, str> },
    #[error("universal manifest validation failed: {manifest}")]
    UniversalValidationFailed { manifest: Cow<'static, str> },
    #[error("unable to find local kumactl")]
    KumactlNotFound,
    #[error("tracked kubectl command requires an active local cluster kubeconfig")]
    TrackedKubectlRequired,
    #[error("kubectl target override is not allowed in tracked runs: {flag}")]
    KubectlTargetOverrideForbidden { flag: Cow<'static, str> },
    #[error("unknown tracked cluster member: {cluster}")]
    UnknownTrackedCluster {
        cluster: Cow<'static, str>,
        choices: Cow<'static, str>,
    },
    #[error("tracked kubeconfig is not a local harness cluster: {path}")]
    NonLocalKubeconfig { path: Cow<'static, str> },
    #[error("envoy config type not found: {type_name}")]
    EnvoyConfigTypeNotFound { type_name: Cow<'static, str> },
    #[error("envoy live capture requires: {fields}")]
    EnvoyCaptureArgsRequired { fields: Cow<'static, str> },
    #[error("report exceeds line limit: {count}>{limit}")]
    ReportLineLimit {
        count: Cow<'static, str>,
        limit: Cow<'static, str>,
    },
    #[error("report exceeds code block limit: {count}>{limit}")]
    ReportCodeBlockLimit {
        count: Cow<'static, str>,
        limit: Cow<'static, str>,
    },
    #[error("no recorded artifact found for evidence label: {label}")]
    EvidenceLabelNotFound { label: Cow<'static, str> },
    #[error("group report requires at least one evidence input")]
    ReportGroupEvidenceRequired,
    #[error("container start failed: {name}")]
    ContainerStartFailed { name: Cow<'static, str> },
    #[error("container not found: {name}")]
    ContainerNotFound { name: Cow<'static, str> },
    #[error("control plane API unreachable: {url}")]
    CpApiUnreachable { url: Cow<'static, str> },
    #[error("dataplane token generation failed: {details}")]
    TokenGenerationFailed { details: Cow<'static, str> },
    #[error("docker network operation failed: {name}")]
    DockerNetworkFailed { name: Cow<'static, str> },
    #[error("docker compose operation failed: {path}")]
    ComposeFileFailed { path: Cow<'static, str> },
    #[error("image build failed: {target}")]
    ImageBuildFailed { target: Cow<'static, str> },
    #[error("template render failed: {detail}")]
    TemplateRender { detail: Cow<'static, str> },
    #[error("service readiness timeout: {name}")]
    ServiceReadinessTimeout { name: Cow<'static, str> },
}

impl RunSetupError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::MissingRunPointer => "KSRCLI005",
            Self::MissingCloseoutArtifact { .. } => "KSRCLI006",
            Self::MissingStateCapture => "KSRCLI007",
            Self::VerdictPending => "KSRCLI008",
            Self::MissingRunContextValue { .. } => "KSRCLI009",
            Self::MissingRunLocation { .. } => "KSRCLI018",
            Self::RunDirExists { .. } => "KSRCLI044",
            Self::MissingRunStatus => "KSRCLI060",
            Self::RunGroupAlreadyRecorded { .. } => "KSRCLI053",
            Self::RunGroupNotFound { .. } => "KSRCLI054",
            Self::GatewayVersionMissing => "KSRCLI032",
            Self::GatewayCrdsMissing => "KSRCLI033",
            Self::GatewayDownloadEmpty { .. } => "KSRCLI061",
            Self::NoResourceKinds { .. } => "KSRCLI030",
            Self::RouteNotFound { .. } => "KSRCLI031",
            Self::UniversalValidationFailed { .. } => "KSRCLI083",
            Self::KumactlNotFound => "KSRCLI034",
            Self::TrackedKubectlRequired => "KSRCLI049",
            Self::KubectlTargetOverrideForbidden { .. } => "KSRCLI050",
            Self::UnknownTrackedCluster { .. } => "KSRCLI051",
            Self::NonLocalKubeconfig { .. } => "KSRCLI052",
            Self::EnvoyConfigTypeNotFound { .. } => "KSRCLI055",
            Self::EnvoyCaptureArgsRequired { .. } => "KSRCLI056",
            Self::ReportLineLimit { .. } => "KSRCLI035",
            Self::ReportCodeBlockLimit { .. } => "KSRCLI036",
            Self::EvidenceLabelNotFound { .. } => "KSRCLI057",
            Self::ReportGroupEvidenceRequired => "KSRCLI058",
            Self::ContainerStartFailed { .. } => "KSRCLI070",
            Self::ContainerNotFound { .. } => "KSRCLI071",
            Self::CpApiUnreachable { .. } => "KSRCLI072",
            Self::TokenGenerationFailed { .. } => "KSRCLI073",
            Self::DockerNetworkFailed { .. } => "KSRCLI074",
            Self::ComposeFileFailed { .. } => "KSRCLI075",
            Self::ImageBuildFailed { .. } => "KSRCLI076",
            Self::TemplateRender { .. } => "KSRCLI077",
            Self::ServiceReadinessTimeout { .. } => "KSRCLI078",
        }
    }

    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::GatewayCrdsMissing
            | Self::ReportLineLimit { .. }
            | Self::ReportCodeBlockLimit { .. } => 1,
            Self::ContainerStartFailed { .. }
            | Self::ContainerNotFound { .. }
            | Self::CpApiUnreachable { .. }
            | Self::TokenGenerationFailed { .. }
            | Self::DockerNetworkFailed { .. }
            | Self::ComposeFileFailed { .. }
            | Self::ImageBuildFailed { .. }
            | Self::TemplateRender { .. }
            | Self::ServiceReadinessTimeout { .. } => 4,
            Self::MissingRunPointer
            | Self::MissingCloseoutArtifact { .. }
            | Self::MissingStateCapture
            | Self::VerdictPending
            | Self::MissingRunContextValue { .. }
            | Self::MissingRunLocation { .. }
            | Self::RunDirExists { .. }
            | Self::MissingRunStatus
            | Self::RunGroupAlreadyRecorded { .. }
            | Self::RunGroupNotFound { .. }
            | Self::GatewayVersionMissing
            | Self::GatewayDownloadEmpty { .. }
            | Self::NoResourceKinds { .. }
            | Self::RouteNotFound { .. }
            | Self::UniversalValidationFailed { .. }
            | Self::KumactlNotFound
            | Self::TrackedKubectlRequired
            | Self::KubectlTargetOverrideForbidden { .. }
            | Self::UnknownTrackedCluster { .. }
            | Self::NonLocalKubeconfig { .. }
            | Self::EnvoyConfigTypeNotFound { .. }
            | Self::EnvoyCaptureArgsRequired { .. }
            | Self::EvidenceLabelNotFound { .. }
            | Self::ReportGroupEvidenceRequired => 5,
        }
    }
}
