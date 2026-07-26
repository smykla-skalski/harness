use super::RunSetupError;

impl RunSetupError {
    /// Advice to print under the error message.
    ///
    /// This crate sits below the command line and cannot see which subcommands
    /// the binaries accept, so a hint here must not name one. Several of these
    /// used to, and went on telling readers to run cluster setup and recording
    /// commands for years after those were retired, because nothing connected
    /// the advice to the surface that would have contradicted it. Describe the
    /// state to fix, or say nothing.
    #[must_use]
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::GatewayDownloadEmpty { .. } => {
                Some("Check the URL and network connectivity.".into())
            }
            Self::KumactlNotFound => Some("Build kumactl first.".into()),
            Self::UnknownTrackedCluster { choices, .. } => Some(format!("Use one of: {choices}.")),
            Self::ReportGroupEvidenceRequired => {
                Some("Pass `--evidence-label <label>` or `--evidence <path>`.".into())
            }
            Self::MissingRunStatus => {
                Some("The run status file could not be loaded. Check the run directory.".into())
            }
            Self::MissingRunPointer
            | Self::MissingRunContextValue { .. }
            | Self::MissingRunLocation { .. }
            | Self::TrackedKubectlRequired
            | Self::KubectlTargetOverrideForbidden { .. }
            | Self::NonLocalKubeconfig { .. }
            | Self::EvidenceLabelNotFound { .. }
            | Self::RunDirExists { .. }
            | Self::ServiceReadinessTimeout { .. }
            | Self::MissingCloseoutArtifact { .. }
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

#[cfg(test)]
#[path = "hints_tests.rs"]
mod tests;
