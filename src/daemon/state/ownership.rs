use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::workspace::normalized_env_value;

use super::DAEMON_OWNERSHIP_ENV;

static OWNERSHIP_OVERRIDE: Mutex<Option<DaemonOwnership>> = Mutex::new(None);

fn ownership_override() -> Option<DaemonOwnership> {
    *OWNERSHIP_OVERRIDE
        .lock()
        .expect("ownership override mutex poisoned")
}

/// Which entry point owns this daemon process.
///
/// Managed daemons are launched by `SMAppService` from the bundled Harness
/// Monitor app. External daemons are launched by `harness daemon dev` from a
/// CLI shell. The two kinds run side-by-side without colliding because they
/// keep their state in separate `<root>/daemon/<ownership>/` subtrees and use
/// distinct launchd labels and bridge ports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DaemonOwnership {
    Managed,
    External,
}

impl DaemonOwnership {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Managed => "managed",
            Self::External => "external",
        }
    }

    /// Parse a value from the `HARNESS_DAEMON_OWNERSHIP` env or a manifest
    /// JSON string. Case-insensitive; trims whitespace. Returns `None` for
    /// unrecognized values so callers can decide how to default.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "managed" => Some(Self::Managed),
            "external" => Some(Self::External),
            _ => None,
        }
    }

    /// Resolve the ownership for the current process. Priority order:
    /// 1. process-local override set via [`ScopedOwnershipOverride`]
    /// 2. `HARNESS_DAEMON_OWNERSHIP` environment variable
    /// 3. default `Managed` (the safer fallback because legacy installs all
    ///    behaved like managed before the coexistence partition existed)
    #[must_use]
    pub fn from_env_or_default() -> Self {
        if let Some(value) = ownership_override() {
            return value;
        }
        normalized_env_value(DAEMON_OWNERSHIP_ENV)
            .as_deref()
            .and_then(Self::parse)
            .unwrap_or(Self::Managed)
    }
}

/// Process-local ownership override that restores the previous value on drop.
/// Mirrors the pattern of `ScopedDaemonRootOverride`. Use from CLI entry
/// points (e.g., `harness daemon dev`) to pin ownership without mutating the
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
        Self { previous }
    }
}

impl Drop for ScopedOwnershipOverride {
    fn drop(&mut self) {
        *OWNERSHIP_OVERRIDE
            .lock()
            .expect("ownership override mutex poisoned") = self.previous;
    }
}

impl Default for DaemonOwnership {
    fn default() -> Self {
        Self::Managed
    }
}

impl std::fmt::Display for DaemonOwnership {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::DaemonOwnership;

    #[test]
    fn parses_canonical_strings() {
        assert_eq!(DaemonOwnership::parse("managed"), Some(DaemonOwnership::Managed));
        assert_eq!(DaemonOwnership::parse("external"), Some(DaemonOwnership::External));
    }

    #[test]
    fn parses_case_insensitively_and_trims() {
        assert_eq!(DaemonOwnership::parse("  Managed\n"), Some(DaemonOwnership::Managed));
        assert_eq!(DaemonOwnership::parse("EXTERNAL"), Some(DaemonOwnership::External));
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
        assert_eq!(serde_json::to_string(&DaemonOwnership::Managed).unwrap(), "\"managed\"");
        assert_eq!(serde_json::to_string(&DaemonOwnership::External).unwrap(), "\"external\"");
    }

    #[test]
    fn display_matches_serde() {
        assert_eq!(DaemonOwnership::Managed.to_string(), "managed");
        assert_eq!(DaemonOwnership::External.to_string(), "external");
    }
}
