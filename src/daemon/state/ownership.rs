use std::sync::Mutex;

pub use harness_protocol::daemon::DaemonOwnership;

use crate::workspace::normalized_env_value;
use harness_telemetry::observe_daemon_ownership_override;

use super::DAEMON_OWNERSHIP_ENV;

static OWNERSHIP_OVERRIDE: Mutex<Option<DaemonOwnership>> = Mutex::new(None);

fn ownership_override() -> Option<DaemonOwnership> {
    *OWNERSHIP_OVERRIDE
        .lock()
        .expect("ownership override mutex poisoned")
}

/// Resolve the ownership for the current process. Priority order:
/// 1. process-local override set via [`ScopedOwnershipOverride`]
/// 2. `HARNESS_DAEMON_OWNERSHIP` environment variable
/// 3. default `Managed` (the safer fallback because legacy installs all
///    behaved like managed before the coexistence partition existed)
///
/// A free function, not a `DaemonOwnership::from_env_or_default()` inherent
/// method, because `DaemonOwnership` now lives in `harness-protocol` and the
/// orphan rule blocks adding inherent methods to a foreign type from here.
#[must_use]
pub fn daemon_ownership_from_env_or_default() -> DaemonOwnership {
    if let Some(value) = ownership_override() {
        return value;
    }
    normalized_env_value(DAEMON_OWNERSHIP_ENV)
        .as_deref()
        .and_then(DaemonOwnership::parse)
        .unwrap_or(DaemonOwnership::Managed)
}

/// Process-local ownership override that restores the previous value on drop.
/// Mirrors the pattern of `ScopedDaemonRootOverride`. Use from CLI entry
/// points (e.g., `harness-daemon dev`) to pin ownership without mutating the
/// process environment.
pub struct ScopedOwnershipOverride {
    previous: Option<DaemonOwnership>,
}

impl ScopedOwnershipOverride {
    #[must_use]
    /// Install a process-local ownership override.
    ///
    /// # Panics
    /// Panics only if the internal mutex is poisoned, which indicates another
    /// thread panicked while holding the override lock.
    pub fn set(value: Option<DaemonOwnership>) -> Self {
        let mut guard = OWNERSHIP_OVERRIDE
            .lock()
            .expect("ownership override mutex poisoned");
        let previous = *guard;
        *guard = value;
        drop(guard);
        // `harness-telemetry` can't depend on this crate to read
        // `OWNERSHIP_OVERRIDE` directly (wrong dependency direction), so its
        // independent daemon-log path resolution needs this mirrored in.
        observe_daemon_ownership_override(
            value.map(|ownership| ownership == DaemonOwnership::External),
        );
        Self { previous }
    }
}

impl Drop for ScopedOwnershipOverride {
    fn drop(&mut self) {
        *OWNERSHIP_OVERRIDE
            .lock()
            .expect("ownership override mutex poisoned") = self.previous;
        observe_daemon_ownership_override(
            self.previous
                .map(|ownership| ownership == DaemonOwnership::External),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::DaemonOwnership;

    #[test]
    fn parses_canonical_strings() {
        assert_eq!(
            DaemonOwnership::parse("managed"),
            Some(DaemonOwnership::Managed)
        );
        assert_eq!(
            DaemonOwnership::parse("external"),
            Some(DaemonOwnership::External)
        );
    }

    #[test]
    fn parses_case_insensitively_and_trims() {
        assert_eq!(
            DaemonOwnership::parse("  Managed\n"),
            Some(DaemonOwnership::Managed)
        );
        assert_eq!(
            DaemonOwnership::parse("EXTERNAL"),
            Some(DaemonOwnership::External)
        );
    }

    #[test]
    fn rejects_unknown_values() {
        assert!(DaemonOwnership::parse("auto").is_none());
        assert!(DaemonOwnership::parse("").is_none());
        assert!(DaemonOwnership::parse("1").is_none());
    }

    #[test]
    fn default_is_managed() {
        assert_eq!(DaemonOwnership::default(), DaemonOwnership::Managed);
    }

    #[test]
    fn round_trips_through_serde() {
        for ownership in [DaemonOwnership::Managed, DaemonOwnership::External] {
            let json = serde_json::to_string(&ownership).expect("serialize");
            let back: DaemonOwnership = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(back, ownership);
        }
    }

    #[test]
    fn serializes_to_lowercase_string() {
        assert_eq!(
            serde_json::to_string(&DaemonOwnership::Managed).unwrap(),
            "\"managed\""
        );
        assert_eq!(
            serde_json::to_string(&DaemonOwnership::External).unwrap(),
            "\"external\""
        );
    }

    #[test]
    fn display_matches_serde() {
        assert_eq!(DaemonOwnership::Managed.to_string(), "managed");
        assert_eq!(DaemonOwnership::External.to_string(), "external");
    }
}
