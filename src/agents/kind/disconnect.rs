//! [`DisconnectReason`] and its hand-written Serde.
//!
//! Split out of the runtime-identity module so the file stays under the
//! repo's 520-line cap and so the disconnect-reason taxonomy has its own
//! home for future variants.

use serde::{Deserialize, Serialize, ser::SerializeStruct};

/// Why an agent transitioned to [`crate::session::types::AgentStatus::Disconnected`].
///
/// Carried alongside the status so the UI can compute restart eligibility
/// from the reason instead of a separate `restartable: bool` flag. New
/// reasons land alongside the call site that emits them. The `Unknown`
/// variant absorbs unknown tags from forward-rolled storage and preserves
/// the original `kind` payload as `raw_kind` so 03:00 forensic triage can
/// see what the writing daemon actually serialised — without that, the
/// older reader silently flattens "this is a reason from a daemon I don't
/// know about" into "we have no idea what happened" and the breadcrumb is
/// gone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DisconnectReason {
    /// Underlying process exited. Optional exit code and signal.
    ProcessExited {
        code: Option<i32>,
        signal: Option<i32>,
    },
    /// Stdio (or PTY) closed unexpectedly with the process still live.
    StdioClosed,
    /// `initialize` did not complete inside its deadline.
    InitializeTimeout,
    /// `session/prompt` did not complete inside its deadline.
    PromptTimeout,
    /// No-events watchdog fired.
    WatchdogFired,
    /// User cancelled the session.
    UserCancelled,
    /// Daemon shut down.
    DaemonShutdown,
    /// Process was OOM-killed.
    OomKilled,
    /// Reason recovered from legacy storage (pre-Chunk-2) or from a future
    /// daemon whose tag this reader does not recognise. `raw_kind` carries
    /// the original `kind` string when present so forensic logs can see
    /// what was on disk.
    Unknown { raw_kind: Option<String> },
}

impl Default for DisconnectReason {
    fn default() -> Self {
        Self::Unknown { raw_kind: None }
    }
}

impl DisconnectReason {
    /// Whether the UI should offer a restart for this disconnection.
    ///
    /// Exhaustive per-arm match (no wildcards) so a future contributor who
    /// adds a variant cannot land it without making the restart decision
    /// visible in the diff. `Unknown` is conservatively non-restartable:
    /// "we don't know what happened" should not silently translate to
    /// "offer a restart" — the operator decides after they see the raw
    /// kind in logs.
    #[must_use]
    pub const fn is_restartable(&self) -> bool {
        match self {
            Self::ProcessExited { .. }
            | Self::StdioClosed
            | Self::WatchdogFired
            | Self::PromptTimeout
            | Self::InitializeTimeout
            | Self::OomKilled => true,
            Self::UserCancelled | Self::DaemonShutdown | Self::Unknown { .. } => false,
        }
    }

    fn kind_str(&self) -> &'static str {
        match self {
            Self::ProcessExited { .. } => KIND_PROCESS_EXITED,
            Self::StdioClosed => KIND_STDIO_CLOSED,
            Self::InitializeTimeout => KIND_INITIALIZE_TIMEOUT,
            Self::PromptTimeout => KIND_PROMPT_TIMEOUT,
            Self::WatchdogFired => KIND_WATCHDOG_FIRED,
            Self::UserCancelled => KIND_USER_CANCELLED,
            Self::DaemonShutdown => KIND_DAEMON_SHUTDOWN,
            Self::OomKilled => KIND_OOM_KILLED,
            Self::Unknown { .. } => KIND_UNKNOWN,
        }
    }
}

// Hand-written Serde so the `Unknown { raw_kind }` variant can capture the
// original `kind` string from forward-rolled storage. `serde(other)` would
// require a unit variant and would erase the tag.

const KIND_PROCESS_EXITED: &str = "process_exited";
const KIND_STDIO_CLOSED: &str = "stdio_closed";
const KIND_INITIALIZE_TIMEOUT: &str = "initialize_timeout";
const KIND_PROMPT_TIMEOUT: &str = "prompt_timeout";
const KIND_WATCHDOG_FIRED: &str = "watchdog_fired";
const KIND_USER_CANCELLED: &str = "user_cancelled";
const KIND_DAEMON_SHUTDOWN: &str = "daemon_shutdown";
const KIND_OOM_KILLED: &str = "oom_killed";
const KIND_UNKNOWN: &str = "unknown";

impl Serialize for DisconnectReason {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::ProcessExited { code, signal } => {
                let mut len = 1;
                if code.is_some() {
                    len += 1;
                }
                if signal.is_some() {
                    len += 1;
                }
                let mut state = serializer.serialize_struct("DisconnectReason", len)?;
                state.serialize_field("kind", KIND_PROCESS_EXITED)?;
                if let Some(code) = code {
                    state.serialize_field("code", code)?;
                }
                if let Some(signal) = signal {
                    state.serialize_field("signal", signal)?;
                }
                state.end()
            }
            Self::Unknown { raw_kind } => {
                let mut state = serializer.serialize_struct("DisconnectReason", 1)?;
                state.serialize_field("kind", raw_kind.as_deref().unwrap_or(KIND_UNKNOWN))?;
                state.end()
            }
            other => {
                let mut state = serializer.serialize_struct("DisconnectReason", 1)?;
                state.serialize_field("kind", other.kind_str())?;
                state.end()
            }
        }
    }
}

#[derive(Deserialize)]
struct OnDisk {
    kind: String,
    #[serde(default)]
    code: Option<i32>,
    #[serde(default)]
    signal: Option<i32>,
}

impl<'de> Deserialize<'de> for DisconnectReason {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = OnDisk::deserialize(deserializer)?;
        Ok(match raw.kind.as_str() {
            KIND_PROCESS_EXITED => Self::ProcessExited {
                code: raw.code,
                signal: raw.signal,
            },
            KIND_STDIO_CLOSED => Self::StdioClosed,
            KIND_INITIALIZE_TIMEOUT => Self::InitializeTimeout,
            KIND_PROMPT_TIMEOUT => Self::PromptTimeout,
            KIND_WATCHDOG_FIRED => Self::WatchdogFired,
            KIND_USER_CANCELLED => Self::UserCancelled,
            KIND_DAEMON_SHUTDOWN => Self::DaemonShutdown,
            KIND_OOM_KILLED => Self::OomKilled,
            KIND_UNKNOWN => Self::Unknown { raw_kind: None },
            other => Self::Unknown {
                raw_kind: Some(other.to_string()),
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        let reasons = [
            DisconnectReason::ProcessExited {
                code: Some(1),
                signal: None,
            },
            DisconnectReason::StdioClosed,
            DisconnectReason::InitializeTimeout,
            DisconnectReason::PromptTimeout,
            DisconnectReason::WatchdogFired,
            DisconnectReason::UserCancelled,
            DisconnectReason::DaemonShutdown,
            DisconnectReason::OomKilled,
            DisconnectReason::Unknown { raw_kind: None },
        ];
        for reason in reasons {
            let json = serde_json::to_string(&reason).expect("serialise");
            let parsed: DisconnectReason = serde_json::from_str(&json).expect("deserialise");
            assert_eq!(parsed, reason);
        }
    }

    #[test]
    fn unknown_kind_preserves_raw_tag_for_forensics() {
        let parsed: DisconnectReason =
            serde_json::from_str(r#"{"kind":"oom_killed_by_cgroup_v2"}"#).expect("deserialise");
        assert_eq!(
            parsed,
            DisconnectReason::Unknown {
                raw_kind: Some("oom_killed_by_cgroup_v2".to_string()),
            }
        );
        // Raw kind round-trips so the next reader also sees what the
        // original writer tagged.
        let json = serde_json::to_string(&parsed).expect("serialise");
        assert!(json.contains("oom_killed_by_cgroup_v2"), "json was {json}");
    }

    #[test]
    fn unknown_default_serializes_as_kind_unknown() {
        let json = serde_json::to_string(&DisconnectReason::default()).expect("serialise");
        assert_eq!(json, r#"{"kind":"unknown"}"#);
    }

    #[test]
    fn is_restartable_unknown_is_conservative_false() {
        // Unknown means we don't know what happened; the operator must
        // decide, not the default. Council finding (hebert): policy
        // hidden in default is worse than a visible decision.
        assert!(!DisconnectReason::Unknown { raw_kind: None }.is_restartable());
        assert!(
            !DisconnectReason::Unknown {
                raw_kind: Some("future_reason".to_string()),
            }
            .is_restartable()
        );
        assert!(!DisconnectReason::UserCancelled.is_restartable());
        assert!(!DisconnectReason::DaemonShutdown.is_restartable());
        assert!(DisconnectReason::OomKilled.is_restartable());
        assert!(DisconnectReason::StdioClosed.is_restartable());
    }
}
