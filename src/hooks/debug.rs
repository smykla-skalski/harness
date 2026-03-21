use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;

use serde::Serialize;

use crate::hooks::protocol::payloads::HookEvent;
use crate::workspace::{session_context_dir, utc_now};

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
#[path = "debug/tests.rs"]
mod tests;
