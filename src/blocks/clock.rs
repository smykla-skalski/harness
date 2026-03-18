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
mod tests {
    use super::*;

    #[test]
    fn system_clock_produces_valid_iso8601() {
        let clock = SystemClock;
        let now = clock.now_iso8601();
        assert!(
            now.contains('T'),
            "expected ISO 8601 with T separator: {now}"
        );
        assert!(now.ends_with('Z'), "expected UTC suffix Z: {now}");
    }

    #[test]
    fn system_clock_rfc3339_matches_iso8601() {
        let clock = SystemClock;
        assert_eq!(clock.now_iso8601(), clock.now_rfc3339());
    }

    #[test]
    fn fake_clock_returns_fixed_value() {
        let clock = FakeClock("2026-01-01T00:00:00Z".to_string());
        assert_eq!(clock.now_iso8601(), "2026-01-01T00:00:00Z");
        assert_eq!(clock.now_rfc3339(), "2026-01-01T00:00:00Z");
    }

    #[test]
    fn clock_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<SystemClock>();
        assert_send_sync::<FakeClock>();
    }
}
