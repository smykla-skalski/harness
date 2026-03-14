use serde::Serialize;

/// Result of a hook evaluation, emitted as JSON on stdout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HookResult {
    pub decision: String,
    pub code: String,
    pub message: String,
}

impl HookResult {
    /// Create an "allow" result with no code or message.
    #[must_use]
    pub fn allow() -> Self {
        Self {
            decision: "allow".to_string(),
            code: String::new(),
            message: String::new(),
        }
    }

    /// Create a "deny" result.
    #[must_use]
    pub fn deny(code: &str, message: &str) -> Self {
        Self {
            decision: "deny".to_string(),
            code: code.to_string(),
            message: message.to_string(),
        }
    }

    /// Create a "warn" result.
    #[must_use]
    pub fn warn(code: &str, message: &str) -> Self {
        Self {
            decision: "warn".to_string(),
            code: code.to_string(),
            message: message.to_string(),
        }
    }

    /// Create an "info" result.
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
mod tests {
    use super::*;

    #[test]
    fn allow_has_empty_fields() {
        let r = HookResult::allow();
        assert_eq!(r.decision, "allow");
        assert!(r.code.is_empty());
        assert!(r.message.is_empty());
    }

    #[test]
    fn deny_sets_fields() {
        let r = HookResult::deny("KSR005", "blocked");
        assert_eq!(r.decision, "deny");
        assert_eq!(r.code, "KSR005");
        assert_eq!(r.message, "blocked");
    }

    #[test]
    fn warn_sets_fields() {
        let r = HookResult::warn("KSR006", "caution");
        assert_eq!(r.decision, "warn");
        assert_eq!(r.code, "KSR006");
        assert_eq!(r.message, "caution");
    }

    #[test]
    fn info_sets_fields() {
        let r = HookResult::info("KSR012", "status ok");
        assert_eq!(r.decision, "info");
        assert_eq!(r.code, "KSR012");
        assert_eq!(r.message, "status ok");
    }

    #[test]
    fn allow_emit_returns_zero_without_output() {
        let r = HookResult::allow();
        assert_eq!(r.emit().unwrap(), 0);
    }

    #[test]
    fn deny_emit_returns_zero() {
        let r = HookResult::deny("X", "msg");
        assert_eq!(r.emit().unwrap(), 0);
    }

    #[test]
    fn serializes_to_json() {
        let r = HookResult::deny("KSR005", "blocked");
        let json = serde_json::to_string(&r).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["decision"], "deny");
        assert_eq!(parsed["code"], "KSR005");
        assert_eq!(parsed["message"], "blocked");
    }

    #[test]
    fn equality() {
        let a = HookResult::deny("X", "m");
        let b = HookResult::deny("X", "m");
        assert_eq!(a, b);
    }

    #[test]
    fn inequality() {
        let a = HookResult::deny("X", "m");
        let b = HookResult::warn("X", "m");
        assert_ne!(a, b);
    }
}
