use std::fmt;

use crate::hook_payloads::HookEvent;

/// Kind of outcome from a hook evaluation.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum OutcomeKind {
    Allowed,
    Error,
    Ignored,
    Skipped,
}

impl fmt::Display for OutcomeKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Allowed => f.write_str("allowed"),
            Self::Error => f.write_str("error"),
            Self::Ignored => f.write_str("ignored"),
            Self::Skipped => f.write_str("skipped"),
        }
    }
}

/// Outcome of a hook evaluation for debug logging.
#[derive(Debug)]
pub struct HookOutcome {
    pub exit_code: i32,
    pub outcome: OutcomeKind,
    pub message: Option<String>,
    pub gate: Option<String>,
}

impl HookOutcome {
    /// Create an "allowed" outcome with exit code 0.
    #[must_use]
    pub fn allow() -> Self {
        Self {
            exit_code: 0,
            outcome: OutcomeKind::Allowed,
            message: None,
            gate: None,
        }
    }

    /// Create an "allowed" outcome with a custom outcome kind.
    #[must_use]
    pub fn allow_with(outcome: OutcomeKind) -> Self {
        Self {
            exit_code: 0,
            outcome,
            message: None,
            gate: None,
        }
    }

    /// Create an "error" outcome with the given exit code.
    #[must_use]
    pub fn error(exit_code: i32) -> Self {
        Self {
            exit_code,
            outcome: OutcomeKind::Error,
            message: None,
            gate: None,
        }
    }

    /// Create an "ignored" outcome with exit code 0.
    #[must_use]
    pub fn ignored() -> Self {
        Self {
            exit_code: 0,
            outcome: OutcomeKind::Ignored,
            message: None,
            gate: None,
        }
    }

    /// Set the message on this outcome.
    #[must_use]
    pub fn with_message(mut self, message: &str) -> Self {
        self.message = Some(message.to_string());
        self
    }

    /// Set the gate on this outcome.
    #[must_use]
    pub fn with_gate(mut self, gate: &str) -> Self {
        self.gate = Some(gate.to_string());
        self
    }

    /// Log the outcome and return the exit code.
    #[must_use]
    pub fn log_and_exit(self, _hook_name: &str, _event: &HookEvent) -> i32 {
        // In the Rust version we skip the JSONL debug logging
        // (the Python version writes to a session-scoped file).
        // The important contract is returning the exit code.
        self.exit_code
    }
}

#[cfg(test)]
mod tests {
    use crate::hook_payloads::HookEnvelopePayload;

    use super::*;

    #[test]
    fn allow_returns_zero_exit_code() {
        let outcome = HookOutcome::allow();
        assert_eq!(outcome.exit_code, 0);
        assert_eq!(outcome.outcome, OutcomeKind::Allowed);
        assert!(outcome.message.is_none());
        assert!(outcome.gate.is_none());
    }

    #[test]
    fn allow_with_sets_custom_outcome() {
        let outcome = HookOutcome::allow_with(OutcomeKind::Skipped);
        assert_eq!(outcome.exit_code, 0);
        assert_eq!(outcome.outcome, OutcomeKind::Skipped);
    }

    #[test]
    fn error_sets_exit_code_and_outcome() {
        let outcome = HookOutcome::error(2);
        assert_eq!(outcome.exit_code, 2);
        assert_eq!(outcome.outcome, OutcomeKind::Error);
    }

    #[test]
    fn ignored_returns_zero_exit_code() {
        let outcome = HookOutcome::ignored();
        assert_eq!(outcome.exit_code, 0);
        assert_eq!(outcome.outcome, OutcomeKind::Ignored);
    }

    #[test]
    fn outcome_kind_display() {
        assert_eq!(OutcomeKind::Allowed.to_string(), "allowed");
        assert_eq!(OutcomeKind::Error.to_string(), "error");
        assert_eq!(OutcomeKind::Ignored.to_string(), "ignored");
        assert_eq!(OutcomeKind::Skipped.to_string(), "skipped");
    }

    #[test]
    fn with_message_sets_message() {
        let outcome = HookOutcome::allow().with_message("all good");
        assert_eq!(outcome.message.as_deref(), Some("all good"));
    }

    #[test]
    fn with_gate_sets_gate() {
        let outcome = HookOutcome::allow().with_gate("prewrite");
        assert_eq!(outcome.gate.as_deref(), Some("prewrite"));
    }

    #[test]
    fn log_and_exit_returns_exit_code() {
        let event = HookEvent {
            payload: HookEnvelopePayload::default(),
        };
        let outcome = HookOutcome::error(3).with_message("fail");
        assert_eq!(outcome.log_and_exit("test-hook", &event), 3);
    }

    #[test]
    fn log_and_exit_returns_zero_for_allow() {
        let event = HookEvent {
            payload: HookEnvelopePayload::default(),
        };
        let outcome = HookOutcome::allow();
        assert_eq!(outcome.log_and_exit("test-hook", &event), 0);
    }
}
