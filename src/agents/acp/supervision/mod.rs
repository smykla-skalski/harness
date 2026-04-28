//! ACP session supervision: deadlines, watchdog, process-group reaping.
//!
//! Supervision enforces:
//!
//! - `initialize` deadline: 30s default
//! - `session/prompt` deadline: 10 min default (configurable per descriptor)
//! - Gateway-aware watchdog: 60s no-events default, paused while any
//!   agent-initiated `Client` call is in flight
//! - Process-group reaper: `killpg(pgid, SIGTERM)` then 3s → `SIGKILL`
//! - Per-session terminal cap (16) and per-terminal wall-clock (5 min)
//!
//! The session owns the main agent process; terminals are managed by the
//! `client::TerminalManager`. Cancellation paths:
//!
//! - window-close → `session/cancel` → drop → killpg cascade
//! - daemon SIGTERM → flush `session/cancel` to all + send `-32099` to pending
#![allow(unsafe_code)]

use std::process::Child;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use tokio::sync::Notify;
use tokio::time::sleep;
use tracing::{debug, info, warn};

use crate::agents::kind::DisconnectReason;

use super::client::DAEMON_SHUTDOWN;

/// Default timeout for the `session/initialize` call.
pub const DEFAULT_INITIALIZE_TIMEOUT: Duration = Duration::from_secs(30);

/// Default timeout for a single `session/prompt` call.
pub const DEFAULT_PROMPT_TIMEOUT: Duration = Duration::from_mins(10);

/// Default watchdog timeout (no events from agent).
pub const DEFAULT_WATCHDOG_TIMEOUT: Duration = Duration::from_mins(1);

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

/// Supervisor for an ACP session.
///
/// Tracks process group, watchdog state, and pending client calls.
pub struct AcpSessionSupervisor {
    pgid: i32,
    pid: u32,
    config: SupervisionConfig,
    state: AtomicU64,
    in_flight_calls: AtomicU64,
    shutting_down: AtomicBool,
    last_event_at: Mutex<Instant>,
    watchdog_notify: Notify,
}

impl AcpSessionSupervisor {
    /// Create a supervisor for a spawned child.
    #[must_use]
    pub fn new(child: &Child, config: SupervisionConfig) -> Self {
        #[cfg(unix)]
        let pgid = child.id().cast_signed();
        #[cfg(not(unix))]
        let pgid = child.id() as i32;

        Self {
            pgid,
            pid: child.id(),
            config,
            state: AtomicU64::new(state_to_u64(WatchdogState::Active)),
            in_flight_calls: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
            last_event_at: Mutex::new(Instant::now()),
            watchdog_notify: Notify::new(),
        }
    }

    /// Record an event from the agent (resets watchdog timer).
    ///
    /// # Panics
    ///
    /// Panics if the mutex is poisoned.
    pub fn record_event(&self) {
        *self.last_event_at.lock().unwrap() = Instant::now();
        self.watchdog_notify.notify_one();
    }

    /// Acquire a client-call guard. While held, the watchdog is paused.
    pub fn enter_client_call(&self) -> ClientCallGuard<'_> {
        self.in_flight_calls.fetch_add(1, Ordering::SeqCst);
        self.update_watchdog_state();
        ClientCallGuard { supervisor: self }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn exit_client_call(&self) {
        let result = self
            .in_flight_calls
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1));
        if result.is_err() {
            warn!("exit_client_call without matching enter; counter already at 0");
        }
        self.update_watchdog_state();
        self.watchdog_notify.notify_one();
    }

    fn update_watchdog_state(&self) {
        let current = self.watchdog_state();
        if current == WatchdogState::Fired || current == WatchdogState::Done {
            return;
        }
        let in_flight = self.in_flight_calls.load(Ordering::SeqCst);
        let new_state = if in_flight > 0 {
            WatchdogState::Paused
        } else {
            WatchdogState::Active
        };
        self.state.store(state_to_u64(new_state), Ordering::SeqCst);
    }

    /// Current watchdog state.
    #[must_use]
    pub fn watchdog_state(&self) -> WatchdogState {
        u64_to_state(self.state.load(Ordering::SeqCst))
    }

    /// Number of in-flight client calls.
    #[must_use]
    pub fn in_flight_call_count(&self) -> u64 {
        self.in_flight_calls.load(Ordering::SeqCst)
    }

    /// Process group id.
    #[must_use]
    pub const fn pgid(&self) -> i32 {
        self.pgid
    }

    /// Process id.
    #[must_use]
    pub const fn pid(&self) -> u32 {
        self.pid
    }

    /// Elapsed time since last event.
    ///
    /// # Panics
    ///
    /// Panics if the mutex is poisoned.
    #[must_use]
    pub fn elapsed_since_last_event(&self) -> Duration {
        self.last_event_at.lock().unwrap().elapsed()
    }

    /// Check if watchdog should fire based on elapsed time and state.
    #[must_use]
    pub fn should_fire_watchdog(&self) -> bool {
        if self.watchdog_state() != WatchdogState::Active {
            return false;
        }
        self.elapsed_since_last_event() >= self.config.watchdog_timeout
    }

    /// Mark watchdog as fired.
    pub fn mark_watchdog_fired(&self) {
        self.state
            .store(state_to_u64(WatchdogState::Fired), Ordering::SeqCst);
    }

    /// Mark session as done.
    pub fn mark_done(&self) {
        self.state
            .store(state_to_u64(WatchdogState::Done), Ordering::SeqCst);
    }

    /// Begin shutdown. Sets flag and returns whether this was the first call.
    pub fn begin_shutdown(&self) -> bool {
        !self.shutting_down.swap(true, Ordering::SeqCst)
    }

    /// Whether shutdown has begun.
    #[must_use]
    pub fn is_shutting_down(&self) -> bool {
        self.shutting_down.load(Ordering::SeqCst)
    }

    /// Configuration reference.
    #[must_use]
    pub const fn config(&self) -> &SupervisionConfig {
        &self.config
    }
}

/// RAII guard that pauses the watchdog while a client call is in flight.
pub struct ClientCallGuard<'a> {
    supervisor: &'a AcpSessionSupervisor,
}

impl Drop for ClientCallGuard<'_> {
    fn drop(&mut self) {
        self.supervisor.exit_client_call();
    }
}

fn state_to_u64(state: WatchdogState) -> u64 {
    match state {
        WatchdogState::Active => 0,
        WatchdogState::Paused => 1,
        WatchdogState::Fired => 2,
        WatchdogState::Done => 3,
    }
}

fn u64_to_state(val: u64) -> WatchdogState {
    match val {
        0 => WatchdogState::Active,
        1 => WatchdogState::Paused,
        2 => WatchdogState::Fired,
        _ => WatchdogState::Done,
    }
}

/// Kill a process group: SIGTERM, wait grace period, then SIGKILL if needed.
///
/// This is a blocking function that sleeps for `SIGTERM_GRACE_PERIOD`. Call it
/// from a dedicated thread or `spawn_blocking`, not directly from an async task.
#[cfg(unix)]
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub fn kill_process_group(pgid: i32, child: &mut Child) {
    info!(pgid, "sending SIGTERM to process group");
    unsafe {
        libc::killpg(pgid, libc::SIGTERM);
    }

    thread::sleep(SIGTERM_GRACE_PERIOD);

    match child.try_wait() {
        Ok(Some(status)) => {
            debug!(pgid, ?status, "process exited after SIGTERM");
        }
        Ok(None) => {
            warn!(
                pgid,
                "process did not exit within grace period; sending SIGKILL"
            );
            unsafe {
                libc::killpg(pgid, libc::SIGKILL);
            }
            let _ = child.wait();
        }
        Err(e) => {
            warn!(pgid, error = %e, "failed to check process status; sending SIGKILL");
            unsafe {
                libc::killpg(pgid, libc::SIGKILL);
            }
            let _ = child.wait();
        }
    }
}

#[cfg(not(unix))]
pub fn kill_process_group(_pgid: i32, child: &mut Child) {
    let _ = child.kill();
}

/// Async watchdog loop. Returns the reason for firing or `None` if cancelled.
///
/// Design: the loop wakes on three events: (1) timeout expiry, (2) `record_event`
/// resets the timer via notify, (3) `exit_client_call` unpauses via notify. This
/// eliminates polling; the loop only wakes when state actually changes. While
/// paused, the loop waits indefinitely - if the client call hangs, so does the
/// watchdog (intentional: "client in call" means "don't kill it").
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub async fn watchdog_loop(supervisor: Arc<AcpSessionSupervisor>) -> Option<DisconnectReason> {
    loop {
        match supervisor.watchdog_state() {
            WatchdogState::Done => return None,
            WatchdogState::Fired => return Some(DisconnectReason::WatchdogFired),
            WatchdogState::Paused => {
                supervisor.watchdog_notify.notified().await;
                continue;
            }
            WatchdogState::Active => {}
        }

        let elapsed = supervisor.elapsed_since_last_event();
        let timeout = supervisor.config().watchdog_timeout;

        if let Some(remaining) = timeout.checked_sub(elapsed) {
            tokio::select! {
                () = sleep(remaining) => {}
                () = supervisor.watchdog_notify.notified() => continue,
            }
        }

        if supervisor.should_fire_watchdog() {
            supervisor.mark_watchdog_fired();
            return Some(DisconnectReason::WatchdogFired);
        }
    }
}

/// JSON-RPC error response for daemon shutdown.
#[derive(Debug, Clone)]
pub struct DaemonShutdownError {
    pub code: i32,
    pub message: String,
}

impl DaemonShutdownError {
    #[must_use]
    pub fn new() -> Self {
        Self {
            code: DAEMON_SHUTDOWN,
            message: "daemon shutdown in progress".to_string(),
        }
    }
}

impl Default for DaemonShutdownError {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests;
