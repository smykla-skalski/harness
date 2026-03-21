mod authoring_observe;
mod common;
mod run_setup;
mod workflow;

use super::{
    AuthoringObserveError, CliError, CliErrorKind, CommonError, RunSetupError, WorkflowError,
};

#[allow(non_upper_case_globals)]
impl CliErrorKind {
    pub const EmptyCommandArgs: Self = Self::Common(CommonError::EmptyCommandArgs);
    pub const MissingRunPointer: Self = Self::RunSetup(RunSetupError::MissingRunPointer);
    pub const MissingStateCapture: Self = Self::RunSetup(RunSetupError::MissingStateCapture);
    pub const VerdictPending: Self = Self::RunSetup(RunSetupError::VerdictPending);
    pub const MissingFrontmatter: Self = Self::Common(CommonError::MissingFrontmatter);
    pub const UnterminatedFrontmatter: Self = Self::Common(CommonError::UnterminatedFrontmatter);
    pub const MarkdownShapeMismatch: Self = Self::Common(CommonError::MarkdownShapeMismatch);
    pub const GatewayVersionMissing: Self = Self::RunSetup(RunSetupError::GatewayVersionMissing);
    pub const GatewayCrdsMissing: Self = Self::RunSetup(RunSetupError::GatewayCrdsMissing);
    pub const KumactlNotFound: Self = Self::RunSetup(RunSetupError::KumactlNotFound);
    pub const ReportGroupEvidenceRequired: Self =
        Self::RunSetup(RunSetupError::ReportGroupEvidenceRequired);
    pub const AuthoringSessionMissing: Self =
        Self::AuthoringObserve(AuthoringObserveError::AuthoringSessionMissing);
    pub const AuthoringPayloadMissing: Self =
        Self::AuthoringObserve(AuthoringObserveError::AuthoringPayloadMissing);
    pub const KubectlValidateDecisionRequired: Self =
        Self::AuthoringObserve(AuthoringObserveError::KubectlValidateDecisionRequired);
    pub const KubectlValidateUnavailable: Self =
        Self::AuthoringObserve(AuthoringObserveError::KubectlValidateUnavailable);
    pub const TrackedKubectlRequired: Self = Self::RunSetup(RunSetupError::TrackedKubectlRequired);
    pub const MissingRunStatus: Self = Self::RunSetup(RunSetupError::MissingRunStatus);
}

impl CliErrorKind {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::Common(error) => error.code(),
            Self::RunSetup(error) => error.code(),
            Self::AuthoringObserve(error) => error.code(),
            Self::Workflow(error) => error.code(),
        }
    }

    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Common(error) => error.exit_code(),
            Self::RunSetup(error) => error.exit_code(),
            Self::AuthoringObserve(error) => error.exit_code(),
            Self::Workflow(_) => WorkflowError::exit_code(),
        }
    }

    #[must_use]
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::Common(_) => CommonError::hint(),
            Self::RunSetup(error) => error.hint(),
            Self::AuthoringObserve(error) => error.hint(),
            Self::Workflow(_) => WorkflowError::hint(),
        }
    }

    #[must_use]
    pub fn with_details(self, details: impl Into<String>) -> CliError {
        CliError::new(self).with_details(details)
    }
}
