use chrono::Utc;

/// Abstraction over wall-clock time for testability.
pub trait Clock: Send + Sync {
    /// Current time as an ISO 8601 / RFC 3339 string (e.g. `2026-03-18T12:00:00Z`).
    fn now_iso8601(&self) -> String;

    /// Alias for `now_iso8601` - both produce the same format in the default impl.
    fn now_rfc3339(&self) -> String {
        self.now_iso8601()
    }
}

/// Production clock backed by `chrono::Utc::now()`.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_iso8601(&self) -> String {
        Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }
}

/// Test clock that returns a fixed timestamp.
#[cfg(test)]
pub struct FakeClock(pub String);

#[cfg(test)]
impl Clock for FakeClock {
    fn now_iso8601(&self) -> String {
        self.0.clone()
    }
}

#[cfg(test)]
#[path = "clock/tests.rs"]
mod tests;
