use serde_json::Value;

use crate::hooks::hook_result::{Decision, HookResult};

/// Agent-agnostic decision used by the hook engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum NormalizedDecision {
    Allow,
    Deny,
    Warn,
    Info,
}

impl From<Decision> for NormalizedDecision {
    fn from(value: Decision) -> Self {
        match value {
            Decision::Allow => Self::Allow,
            Decision::Deny => Self::Deny,
            Decision::Warn => Self::Warn,
            Decision::Info => Self::Info,
        }
    }
}

impl From<NormalizedDecision> for Decision {
    fn from(value: NormalizedDecision) -> Self {
        match value {
            NormalizedDecision::Allow => Self::Allow,
            NormalizedDecision::Deny => Self::Deny,
            NormalizedDecision::Warn => Self::Warn,
            NormalizedDecision::Info => Self::Info,
        }
    }
}

/// Agent-agnostic hook result rendered by adapters.
#[derive(Debug, Clone, PartialEq)]
pub struct NormalizedHookResult {
    pub decision: NormalizedDecision,
    pub reason: Option<String>,
    pub code: Option<String>,
    pub additional_context: Option<String>,
    pub updated_input: Option<Value>,
    pub suppress_output: bool,
    pub halt_agent: bool,
    pub extensions: Value,
}

impl NormalizedHookResult {
    #[must_use]
    pub fn allow() -> Self {
        Self {
            decision: NormalizedDecision::Allow,
            reason: None,
            code: None,
            additional_context: None,
            updated_input: None,
            suppress_output: false,
            halt_agent: false,
            extensions: Value::Null,
        }
    }

    #[must_use]
    pub fn deny(code: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            decision: NormalizedDecision::Deny,
            reason: Some(reason.into()),
            code: Some(code.into()),
            additional_context: None,
            updated_input: None,
            suppress_output: false,
            halt_agent: false,
            extensions: Value::Null,
        }
    }

    #[must_use]
    pub fn warn(code: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            decision: NormalizedDecision::Warn,
            reason: Some(reason.into()),
            code: Some(code.into()),
            additional_context: None,
            updated_input: None,
            suppress_output: false,
            halt_agent: false,
            extensions: Value::Null,
        }
    }

    #[must_use]
    pub fn info(code: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            decision: NormalizedDecision::Info,
            reason: Some(reason.into()),
            code: Some(code.into()),
            additional_context: None,
            updated_input: None,
            suppress_output: false,
            halt_agent: false,
            extensions: Value::Null,
        }
    }

    #[must_use]
    pub fn from_hook_result(result: HookResult) -> Self {
        Self {
            decision: result.decision.into(),
            reason: (!result.message.is_empty()).then_some(result.message),
            code: (!result.code.is_empty()).then_some(result.code),
            additional_context: None,
            updated_input: None,
            suppress_output: false,
            halt_agent: false,
            extensions: Value::Null,
        }
    }

    #[must_use]
    pub fn with_additional_context(mut self, context: impl Into<String>) -> Self {
        self.additional_context = Some(context.into());
        self
    }

    #[must_use]
    pub fn with_updated_input(mut self, updated_input: Value) -> Self {
        self.updated_input = Some(updated_input);
        self
    }

    #[must_use]
    pub fn with_halt(mut self) -> Self {
        self.halt_agent = true;
        self
    }

    #[must_use]
    pub fn is_denial(&self) -> bool {
        self.decision == NormalizedDecision::Deny
    }

    #[must_use]
    pub fn display_message(&self) -> String {
        let message = self
            .additional_context
            .as_deref()
            .filter(|message| !message.is_empty())
            .or(self.reason.as_deref())
            .unwrap_or_default();
        let Some(code) = self.code.as_deref() else {
            return message.to_string();
        };
        let level = match self.decision {
            NormalizedDecision::Warn => "WARNING",
            NormalizedDecision::Info => "INFO",
            NormalizedDecision::Allow | NormalizedDecision::Deny => "ERROR",
        };
        if message.is_empty() {
            format!("{level} [{code}]")
        } else {
            format!("{level} [{code}] {message}")
        }
    }

    #[must_use]
    pub fn to_hook_result(&self) -> HookResult {
        HookResult {
            decision: self.decision.into(),
            code: self.code.clone().unwrap_or_default(),
            message: self
                .additional_context
                .clone()
                .or_else(|| self.reason.clone())
                .unwrap_or_default(),
        }
    }
}
