use std::borrow::Cow;

use super::HookMessage;

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

    pub fn suite_amendment_required(path: impl Into<Cow<'static, str>>) -> Self {
        Self::SuiteAmendmentRequired { path: path.into() }
    }
}
