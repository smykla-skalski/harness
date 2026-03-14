use serde::Serialize;

/// Result of a hook evaluation, emitted as JSON on stdout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HookResult {
    pub decision: String,
    pub code: String,
    pub message: String,
}

impl HookResult {
    #[must_use]
    pub fn allow() -> Self {
        Self {
            decision: "allow".to_string(),
            code: String::new(),
            message: String::new(),
        }
    }

    #[must_use]
    pub fn deny(code: &str, message: &str) -> Self {
        Self {
            decision: "deny".to_string(),
            code: code.to_string(),
            message: message.to_string(),
        }
    }

    #[must_use]
    pub fn warn(code: &str, message: &str) -> Self {
        Self {
            decision: "warn".to_string(),
            code: code.to_string(),
            message: message.to_string(),
        }
    }

    #[must_use]
    pub fn info(code: &str, message: &str) -> Self {
        Self {
            decision: "info".to_string(),
            code: code.to_string(),
            message: message.to_string(),
        }
    }

    /// Emit the hook result as JSON to stdout. Returns 0 (exit code).
    ///
    /// # Errors
    /// Returns an error if JSON serialization fails.
    pub fn emit(&self) -> Result<i32, serde_json::Error> {
        if self.decision == "allow" && self.code.is_empty() {
            return Ok(0);
        }
        let json = serde_json::to_string(self)?;
        println!("{json}");
        Ok(0)
    }
}

#[cfg(test)]
mod tests {}
