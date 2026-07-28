//! Supervision tunables and the observable watchdog state.

use std::time::Duration;

/// Default timeout for the `session/initialize` call.
pub const DEFAULT_INITIALIZE_TIMEOUT: Duration = Duration::from_secs(30);

/// Default timeout for a single `session/prompt` call.
pub const DEFAULT_PROMPT_TIMEOUT: Duration = Duration::from_mins(10);

/// Default timeout for a session lifecycle call such as `session/new` or
/// `session/close`.
///
/// These carry no model work, so they get the startup budget rather than the
/// prompt budget. An agent that stops answering one of them would otherwise
/// block its caller thread with no way out.
pub const DEFAULT_LIFECYCLE_TIMEOUT: Duration = Duration::from_secs(30);

/// Default watchdog timeout (no events from agent).
pub const DEFAULT_WATCHDOG_TIMEOUT: Duration = Duration::from_mins(5);

/// Grace period between SIGTERM and SIGKILL.
pub const SIGTERM_GRACE_PERIOD: Duration = Duration::from_secs(3);

/// Maximum terminals per session. Exported for `client::TerminalManager` enforcement.
pub const MAX_TERMINALS_PER_SESSION: usize = 16;

/// Maximum wall-clock time per terminal. Exported for `client::TerminalManager` enforcement.
pub const MAX_TERMINAL_WALL_CLOCK: Duration = Duration::from_mins(5);

/// Supervision configuration for an ACP session.
#[derive(Debug, Clone)]
pub struct SupervisionConfig {
    /// Maximum time for `session/initialize`.
    pub initialize_timeout: Duration,
    /// Maximum time for a single `session/prompt`.
    pub prompt_timeout: Duration,
    /// Maximum time for a session lifecycle call.
    pub lifecycle_timeout: Duration,
    /// Watchdog timeout (no events from agent).
    pub watchdog_timeout: Duration,
    /// Maximum terminals per session.
    pub terminal_cap: usize,
    /// Maximum wall-clock per terminal.
    pub terminal_wall_clock: Duration,
}

impl Default for SupervisionConfig {
    fn default() -> Self {
        Self {
            initialize_timeout: DEFAULT_INITIALIZE_TIMEOUT,
            prompt_timeout: DEFAULT_PROMPT_TIMEOUT,
            lifecycle_timeout: DEFAULT_LIFECYCLE_TIMEOUT,
            watchdog_timeout: DEFAULT_WATCHDOG_TIMEOUT,
            terminal_cap: MAX_TERMINALS_PER_SESSION,
            terminal_wall_clock: MAX_TERMINAL_WALL_CLOCK,
        }
    }
}

impl SupervisionConfig {
    /// Create config from a descriptor's `prompt_timeout_seconds` override.
    #[must_use]
    pub fn with_prompt_timeout(mut self, seconds: Option<u64>) -> Self {
        if let Some(s) = seconds {
            self.prompt_timeout = Duration::from_secs(s);
        }
        self
    }
}

/// Observable state of the gateway-aware watchdog.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchdogState {
    /// Watchdog is counting down.
    Active,
    /// Watchdog is paused (agent-initiated Client call in flight).
    Paused,
    /// Watchdog fired.
    Fired,
    /// Session completed normally.
    Done,
}

impl WatchdogState {
    /// Human-readable label for observability.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Fired => "fired",
            Self::Done => "done",
        }
    }
}
