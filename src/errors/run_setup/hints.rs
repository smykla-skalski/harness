use super::RunSetupError;

impl RunSetupError {
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
