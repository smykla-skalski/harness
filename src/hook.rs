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
mod tests {
    use super::*;

    #[test]
    fn allow_has_empty_code_and_message() {
        let r = HookResult::allow();
        assert_eq!(r.decision, Decision::Allow);
        assert!(r.code.is_empty());
        assert!(r.message.is_empty());
    }

    #[test]
    fn deny_has_correct_decision() {
        let r = HookResult::deny("KSR005", "bad");
        assert_eq!(r.decision, Decision::Deny);
        assert_eq!(r.code, "KSR005");
        assert_eq!(r.message, "bad");
    }

    #[test]
    fn warn_has_correct_decision() {
        let r = HookResult::warn("KSR006", "watch out");
        assert_eq!(r.decision, Decision::Warn);
        assert_eq!(r.code, "KSR006");
        assert_eq!(r.message, "watch out");
    }

    #[test]
    fn info_has_correct_decision() {
        let r = HookResult::info("KSR012", "verdict: pass");
        assert_eq!(r.decision, Decision::Info);
        assert_eq!(r.code, "KSR012");
        assert_eq!(r.message, "verdict: pass");
    }

    #[test]
    fn emit_allow_returns_zero() {
        let r = HookResult::allow();
        assert_eq!(r.emit().unwrap(), 0);
    }

    #[test]
    fn emit_deny_returns_zero() {
        let r = HookResult::deny("X", "msg");
        assert_eq!(r.emit().unwrap(), 0);
    }

    #[test]
    fn serialize_to_json() {
        let r = HookResult::deny("KSR005", "test message");
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["decision"], "deny");
        assert_eq!(json["code"], "KSR005");
        assert_eq!(json["message"], "test message");
    }

    #[test]
    fn equality() {
        let a = HookResult::deny("X", "msg");
        let b = HookResult::deny("X", "msg");
        assert_eq!(a, b);
    }

    #[test]
    fn inequality_different_decision() {
        let a = HookResult::deny("X", "msg");
        let b = HookResult::warn("X", "msg");
        assert_ne!(a, b);
    }

    #[test]
    fn clone_is_equal() {
        let a = HookResult::info("KSR012", "test");
        let b = a.clone();
        assert_eq!(a, b);
    }
}
