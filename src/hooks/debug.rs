use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;

use serde::Serialize;

use crate::workspace::{session_context_dir, utc_now};
use crate::hooks::protocol::payloads::HookEvent;

/// A single JSONL debug log entry.
#[derive(Serialize)]
struct DebugLine {
    hook_name: String,
    timestamp: String,
    exit_code: i32,
    outcome: String,
    message: Option<String>,
    gate: Option<String>,
}

/// Append a JSON debug line to the session-scoped hooks-debug.jsonl file.
/// Silently returns on any error - debug logging must not crash hooks.
fn write_debug_line(hook_name: &str, outcome: &HookOutcome) {
    let Ok(ctx_dir) = session_context_dir() else {
        return;
    };
    let _ = fs::create_dir_all(&ctx_dir);
    let debug_path = ctx_dir.join("hooks-debug.jsonl");
    let line = DebugLine {
        hook_name: hook_name.to_string(),
        timestamp: utc_now(),
        exit_code: outcome.exit_code,
        outcome: outcome.outcome.to_string(),
        message: outcome.message.clone(),
        gate: outcome.gate.clone(),
    };
    let Ok(json) = serde_json::to_string(&line) else {
        return;
    };
    let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&debug_path)
    else {
        return;
    };
    let _ = writeln!(file, "{json}");
}

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

    /// Log the outcome to the session debug file and return the exit code.
    #[must_use]
    pub fn log_and_exit(self, hook_name: &str, _event: &HookEvent) -> i32 {
        write_debug_line(hook_name, &self);
        self.exit_code
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::cognitive_complexity)]

    use std::fs as stdfs;

    use crate::workspace::session_context_dir;
    use crate::hooks::protocol::payloads::HookEnvelopePayload;

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

    #[test]
    fn log_and_exit_writes_jsonl_debug_file() {
        let tmp = tempfile::tempdir().unwrap();
        let xdg = tmp.path().join("xdg");
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("debug-test-session")),
            ],
            || {
                let event = HookEvent {
                    payload: HookEnvelopePayload::default(),
                };
                let outcome = HookOutcome::error(2)
                    .with_message("blocked")
                    .with_gate("prebash");
                let code = outcome.log_and_exit("guard-bash", &event);
                assert_eq!(code, 2);

                let ctx_dir = session_context_dir().unwrap();
                let debug_path = ctx_dir.join("hooks-debug.jsonl");
                assert!(debug_path.exists(), "debug file should exist");

                let content = stdfs::read_to_string(&debug_path).unwrap();
                let line: serde_json::Value = serde_json::from_str(
                    content
                        .lines()
                        .last()
                        .expect("debug file should contain at least one JSONL line"),
                )
                .unwrap();
                assert_eq!(line["hook_name"], "guard-bash");
                assert_eq!(line["exit_code"], 2);
                assert_eq!(line["outcome"], "error");
                assert_eq!(line["message"], "blocked");
                assert_eq!(line["gate"], "prebash");
                assert!(line["timestamp"].as_str().unwrap().ends_with('Z'));
            },
        );
    }
}
