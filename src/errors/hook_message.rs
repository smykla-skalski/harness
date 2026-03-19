use std::borrow::Cow;

use crate::hooks::protocol::hook_result::{Decision, HookResult};

/// Enum of all hook messages, replacing the static `HookDef` definitions.
///
/// Each variant carries its data as fields. `Display` is derived by thiserror.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum HookMessage {
    #[error("Run cluster interactions through `harness run ...` or another `harness` wrapper.")]
    ClusterBinary,

    #[error(
        "Envoy admin calls must go through `harness run envoy` or another tracked \
         `harness` wrapper. Prefer one live `harness run envoy ...` command over \
         capture-then-read flows."
    )]
    AdminEndpoint,

    #[error("Run closeout is incomplete: missing final state capture.")]
    MissingStateCapture,

    #[error(
        "Run closeout is incomplete: verdict is still pending. \
         Run `harness run runner-state --event abort` to mark the run as aborted \
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

    #[error(
        "Bug or failure detected during test execution. \
         Use AskUserQuestion with the bug-found gate before continuing. \
         Command: {command}"
    )]
    BugFoundGateRequired { command: Cow<'static, str> },

    #[error("Expected artifact missing after {script}: {target}")]
    MissingArtifact {
        script: Cow<'static, str>,
        target: Cow<'static, str>,
    },

    #[error("Run `harness run preflight` before the first cluster mutation.")]
    RunPreflight,

    #[error("Expected preflight artifacts are missing or incomplete.")]
    PreflightMissing,

    #[error(
        "Suite:new workers must save structured results through \
         `harness authoring save` and return only a short acknowledgement."
    )]
    CodeReaderFormat,

    #[error("Suite:new worker reply is missing the expected acknowledgement for `{sections}`.")]
    ReaderMissingSections { sections: Cow<'static, str> },

    #[error(
        "Suite:new worker reply is oversized; save the structured payload \
         and return a short acknowledgement only."
    )]
    ReaderOversizedBlock,

    #[error(
        "Subshell substitution containing a denied binary was detected. \
         Run cluster interactions through `harness run ...` or another `harness` wrapper."
    )]
    SubshellSmuggling,

    #[error("Suite:run runs must stay user-story-first and tracked.")]
    SuiteRunnerTracked,

    #[error("Current run verdict: {verdict}")]
    RunVerdict { verdict: Cow<'static, str> },

    #[error("Suites must stay user-story-first with concrete variant evidence.")]
    SuiteAuthorTracked,
}

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

    pub fn bug_found_gate_required(command: impl Into<Cow<'static, str>>) -> Self {
        Self::BugFoundGateRequired {
            command: command.into(),
        }
    }

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
            Self::SuiteAuthorTracked => "KSA008",
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
            Self::SuiteRunnerTracked | Self::RunVerdict { .. } | Self::SuiteAuthorTracked => {
                Decision::Info
            }
        }
    }

    #[must_use]
    pub fn into_result(self) -> HookResult {
        let code = self.code().to_string();
        let message = self.to_string();
        match self.decision() {
            Decision::Deny => HookResult::deny(code, message),
            Decision::Warn => HookResult::warn(code, message),
            Decision::Info => HookResult::info(code, message),
            Decision::Allow => HookResult::allow(),
        }
    }
}
