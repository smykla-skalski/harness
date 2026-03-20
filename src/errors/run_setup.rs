use std::borrow::Cow;

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

    #[must_use]
    pub fn missing_closeout_artifact(rel: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingCloseoutArtifact { rel: rel.into() }
    }

    #[must_use]
    pub fn missing_run_context_value(field: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingRunContextValue {
            field: field.into(),
        }
    }

    #[must_use]
    pub fn missing_run_location(run_id: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingRunLocation {
            run_id: run_id.into(),
        }
    }

    #[must_use]
    pub fn run_dir_exists(run_dir: impl Into<Cow<'static, str>>) -> Self {
        Self::RunDirExists {
            run_dir: run_dir.into(),
        }
    }

    #[must_use]
    pub fn run_group_already_recorded(group_id: impl Into<Cow<'static, str>>) -> Self {
        Self::RunGroupAlreadyRecorded {
            group_id: group_id.into(),
        }
    }

    #[must_use]
    pub fn run_group_not_found(group_id: impl Into<Cow<'static, str>>) -> Self {
        Self::RunGroupNotFound {
            group_id: group_id.into(),
        }
    }

    #[must_use]
    pub fn gateway_download_empty(path: impl Into<Cow<'static, str>>) -> Self {
        Self::GatewayDownloadEmpty { path: path.into() }
    }

    #[must_use]
    pub fn no_resource_kinds(manifest: impl Into<Cow<'static, str>>) -> Self {
        Self::NoResourceKinds {
            manifest: manifest.into(),
        }
    }

    #[must_use]
    pub fn route_not_found(route_match: impl Into<Cow<'static, str>>) -> Self {
        Self::RouteNotFound {
            route_match: route_match.into(),
        }
    }

    #[must_use]
    pub fn universal_validation_failed(manifest: impl Into<Cow<'static, str>>) -> Self {
        Self::UniversalValidationFailed {
            manifest: manifest.into(),
        }
    }

    #[must_use]
    pub fn kubectl_target_override_forbidden(flag: impl Into<Cow<'static, str>>) -> Self {
        Self::KubectlTargetOverrideForbidden { flag: flag.into() }
    }

    #[must_use]
    pub fn unknown_tracked_cluster(
        cluster: impl Into<Cow<'static, str>>,
        choices: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::UnknownTrackedCluster {
            cluster: cluster.into(),
            choices: choices.into(),
        }
    }

    #[must_use]
    pub fn non_local_kubeconfig(path: impl Into<Cow<'static, str>>) -> Self {
        Self::NonLocalKubeconfig { path: path.into() }
    }

    #[must_use]
    pub fn envoy_config_type_not_found(type_name: impl Into<Cow<'static, str>>) -> Self {
        Self::EnvoyConfigTypeNotFound {
            type_name: type_name.into(),
        }
    }

    #[must_use]
    pub fn envoy_capture_args_required(fields: impl Into<Cow<'static, str>>) -> Self {
        Self::EnvoyCaptureArgsRequired {
            fields: fields.into(),
        }
    }

    #[must_use]
    pub fn report_line_limit(
        count: impl Into<Cow<'static, str>>,
        limit: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::ReportLineLimit {
            count: count.into(),
            limit: limit.into(),
        }
    }

    #[must_use]
    pub fn report_code_block_limit(
        count: impl Into<Cow<'static, str>>,
        limit: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::ReportCodeBlockLimit {
            count: count.into(),
            limit: limit.into(),
        }
    }

    #[must_use]
    pub fn evidence_label_not_found(label: impl Into<Cow<'static, str>>) -> Self {
        Self::EvidenceLabelNotFound {
            label: label.into(),
        }
    }

    #[must_use]
    pub fn container_start_failed(name: impl Into<Cow<'static, str>>) -> Self {
        Self::ContainerStartFailed { name: name.into() }
    }

    #[must_use]
    pub fn container_not_found(name: impl Into<Cow<'static, str>>) -> Self {
        Self::ContainerNotFound { name: name.into() }
    }

    #[must_use]
    pub fn cp_api_unreachable(url: impl Into<Cow<'static, str>>) -> Self {
        Self::CpApiUnreachable { url: url.into() }
    }

    #[must_use]
    pub fn token_generation_failed(details: impl Into<Cow<'static, str>>) -> Self {
        Self::TokenGenerationFailed {
            details: details.into(),
        }
    }

    #[must_use]
    pub fn docker_network_failed(name: impl Into<Cow<'static, str>>) -> Self {
        Self::DockerNetworkFailed { name: name.into() }
    }

    #[must_use]
    pub fn compose_file_failed(path: impl Into<Cow<'static, str>>) -> Self {
        Self::ComposeFileFailed { path: path.into() }
    }

    #[must_use]
    pub fn image_build_failed(target: impl Into<Cow<'static, str>>) -> Self {
        Self::ImageBuildFailed {
            target: target.into(),
        }
    }

    #[must_use]
    pub fn template_render(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::TemplateRender {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn service_readiness_timeout(name: impl Into<Cow<'static, str>>) -> Self {
        Self::ServiceReadinessTimeout { name: name.into() }
    }

    #[must_use]
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::MissingRunPointer => Some("Run init first.".into()),
            Self::MissingRunContextValue { .. } => {
                Some("Run `harness run init` and the required setup step first.".into())
            }
            Self::MissingRunLocation { .. } => {
                Some("Pass `--run-root` or `--run-dir`, or run `harness run init` first.".into())
            }
            Self::GatewayDownloadEmpty { .. } => {
                Some("Check the URL and network connectivity.".into())
            }
            Self::KumactlNotFound => Some("Build kumactl first.".into()),
            Self::TrackedKubectlRequired => {
                Some("Run `harness run init` and `harness setup kuma cluster ...` first.".into())
            }
            Self::KubectlTargetOverrideForbidden { .. } => Some(
                "Use `harness run record --cluster <name> -- kubectl ...` for another tracked member.".into(),
            ),
            Self::UnknownTrackedCluster { choices, .. } => Some(format!("Use one of: {choices}.")),
            Self::NonLocalKubeconfig { .. } => Some(
                "Recreate the local cluster with `harness setup kuma cluster ...` before continuing.".into(),
            ),
            Self::EvidenceLabelNotFound { .. } => Some(
                "Use `harness run record --label <label>` or inspect `commands/command-log.md`."
                    .into(),
            ),
            Self::ReportGroupEvidenceRequired => {
                Some("Pass `--evidence-label <label>` or `--evidence <path>`.".into())
            }
            Self::RunDirExists { .. } => Some(
                "Use a new run id or resume the existing run instead of re-running `harness run init`."
                    .into(),
            ),
            Self::MissingRunStatus => Some(
                "The run-status.json file could not be loaded. Re-run `harness run init` or check the run directory."
                    .into(),
            ),
            Self::ServiceReadinessTimeout { name } => Some(format!(
                "Run `harness run kuma service down {name}` to clean up the container."
            )),
            Self::MissingCloseoutArtifact { .. }
            | Self::MissingStateCapture
            | Self::VerdictPending
            | Self::RunGroupAlreadyRecorded { .. }
            | Self::RunGroupNotFound { .. }
            | Self::GatewayVersionMissing
            | Self::GatewayCrdsMissing
            | Self::NoResourceKinds { .. }
            | Self::RouteNotFound { .. }
            | Self::UniversalValidationFailed { .. }
            | Self::EnvoyConfigTypeNotFound { .. }
            | Self::EnvoyCaptureArgsRequired { .. }
            | Self::ReportLineLimit { .. }
            | Self::ReportCodeBlockLimit { .. }
            | Self::ContainerStartFailed { .. }
            | Self::ContainerNotFound { .. }
            | Self::CpApiUnreachable { .. }
            | Self::TokenGenerationFailed { .. }
            | Self::DockerNetworkFailed { .. }
            | Self::ComposeFileFailed { .. }
            | Self::ImageBuildFailed { .. }
            | Self::TemplateRender { .. } => None,
        }
    }
}
