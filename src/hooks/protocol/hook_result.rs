use serde::Serialize;

/// The decision a hook emits: allow, deny, warn, or info.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
#[non_exhaustive]
pub enum Decision {
    Allow,
    Deny,
    Warn,
    Info,
}

/// Result of a hook evaluation, emitted as JSON on stdout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HookResult {
    pub decision: Decision,
    pub code: String,
    pub message: String,
}

impl HookResult {
    #[must_use]
    pub fn allow() -> Self {
        Self {
            decision: Decision::Allow,
            code: String::new(),
            message: String::new(),
        }
    }

    #[must_use]
    pub fn deny(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            decision: Decision::Deny,
            code: code.into(),
            message: message.into(),
        }
    }

    #[must_use]
    pub fn warn(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            decision: Decision::Warn,
            code: code.into(),
            message: message.into(),
        }
    }

    #[must_use]
    pub fn info(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            decision: Decision::Info,
            code: code.into(),
            message: message.into(),
        }
    }

    /// Returns `true` when this result is a denial (non-empty code).
    #[must_use]
    pub fn is_denial(&self) -> bool {
        self.decision == Decision::Deny
    }

    /// Converts this result into `Some(self)` when it is a denial, `None`
    /// otherwise. Useful for short-circuiting a sequence of guard checks.
    #[must_use]
    pub fn into_denial(self) -> Option<Self> {
        if self.is_denial() { Some(self) } else { None }
    }

    /// Emit the hook result as JSON to stdout. Returns 0 (exit code).
    ///
    /// # Errors
    /// Returns an error if JSON serialization fails.
    pub fn emit(&self) -> Result<i32, serde_json::Error> {
        if self.decision == Decision::Allow && self.code.is_empty() {
            return Ok(0);
        }
        let json = serde_json::to_string(self)?;
        println!("{json}");
        Ok(0)
    }
}

#[cfg(test)]
#[path = "hook_result/tests.rs"]
mod tests;
