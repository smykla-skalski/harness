use crate::hooks::protocol::hook_result::Decision;

use super::HookMessage;

impl HookMessage {
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
            Self::SubshellSmuggling => "KSR017",
            Self::WriteOutsideSuite { .. } => "KSA001",
            Self::ApprovalStateInvalid { .. } => "KSA002",
            Self::ApprovalRequired { .. } => "KSA003",
            Self::GroupsNotList | Self::BaselinesNotList | Self::SuiteIncomplete { .. } => "KSA004",
            Self::CodeReaderFormat => "KSA006",
            Self::ReaderMissingSections { .. } | Self::ReaderOversizedBlock => "KSA007",
            Self::SuiteCreateTracked => "KSA008",
            Self::ValidatorGateRequired { .. } => "KSA009",
            Self::ValidatorInstallFailed { .. } => "KSA010",
            Self::ValidatorGateUnexpected { .. } => "KSA011",
            Self::BugFoundGateRequired { .. } => "KSR016",
        }
    }

    #[must_use]
    pub fn decision(&self) -> Decision {
        match self {
            Self::ClusterBinary
            | Self::AdminEndpoint
            | Self::SubshellSmuggling
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
            | Self::ValidatorGateUnexpected { .. }
            | Self::BugFoundGateRequired { .. } => Decision::Deny,
            Self::MissingArtifact { .. }
            | Self::RunPreflight
            | Self::PreflightMissing
            | Self::CodeReaderFormat
            | Self::ReaderMissingSections { .. }
            | Self::ReaderOversizedBlock => Decision::Warn,
            Self::SuiteRunnerTracked | Self::RunVerdict { .. } | Self::SuiteCreateTracked => {
                Decision::Info
            }
        }
    }
}
