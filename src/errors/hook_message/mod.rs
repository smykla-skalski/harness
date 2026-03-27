use std::borrow::Cow;

mod constructors;
mod mapping;

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

    #[error("Write path is outside the suite:create surface: {path}")]
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
         `harness create save` and return only a short acknowledgement."
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
    SuiteCreateTracked,

    #[error(
        "Observe loops are still active. Run CronList to find active observe jobs, \
         then CronDelete each one before stopping. Do not rely on session cleanup."
    )]
    ObserveLoopsActive,
}

impl HookMessage {
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
