//! ACP session supervision: deadlines, watchdog, process-group reaping.
//!
//! Supervision enforces:
//!
//! - `initialize` deadline: 30s default
//! - `session/prompt` deadline: 10 min default (configurable per descriptor)
//! - Pending-request watchdog: 5 min no-events default, only Active while a
//!   daemon-issued request (initialize, `new_session`, prompt) is awaiting an
//!   agent response. Paused for idle agents and while any agent-initiated
//!   `Client` call is in flight (daemon is the one processing then).
//! - Process-group reaper: `killpg(pgid, SIGTERM)` then 3s → `SIGKILL`
//! - Per-session terminal cap (16) and per-terminal wall-clock (5 min)
//!
//! The session owns the main agent process; terminals are managed by the
//! `client::TerminalManager`. Cancellation paths:
//!
//! - window-close → `session/cancel` → drop → killpg cascade
//! - daemon SIGTERM → flush `session/cancel` to all + send `-32099` to pending
use std::process::Child;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use tokio::time::Instant;

use tokio::sync::Notify;
use tracing::warn;

use harness_protocol::managed_agents::acp::{AcpAgentHandshake, AcpAgentSessionState};

use crate::agents::kind::DisconnectReason;
use crate::workspace::utc_now;

mod config;
mod guards;
mod process;
mod shutdown;
mod watchdog;

pub use config::{
    DEFAULT_INITIALIZE_TIMEOUT, DEFAULT_PROMPT_TIMEOUT, DEFAULT_WATCHDOG_TIMEOUT,
    MAX_TERMINAL_WALL_CLOCK, MAX_TERMINALS_PER_SESSION, SIGTERM_GRACE_PERIOD, SupervisionConfig,
    WatchdogState,
};
pub use guards::{ClientCallGuard, PendingRequestGuard};
pub use process::SupervisedProcess;
pub use shutdown::{DaemonShutdownError, kill_process_group};
pub use watchdog::watchdog_loop;

/// Sink for synthetic supervisor-side events surfaced to the conversation
/// timeline (watchdog state, permission gates, wake-prompt context acks).
///
/// The supervisor and ACP wake-accept path call these emit methods from
/// synchronous contexts; implementations must be non-blocking (e.g.
/// `mpsc::Sender::try_send`) so they cannot stall the producer. Methods
/// other than `emit_state` default to no-op so test doubles that only care
/// about watchdog can ignore them.
pub trait WatchdogEventEmitter: Send + Sync {
    /// Emit a watchdog state transition for downstream timeline consumers.
    fn emit_state(&self, from: WatchdogState, to: WatchdogState, reason: Option<&str>);

    /// Emit a permission-prompt event surfaced by the ACP client gate.
    /// Default no-op so non-ACP impls (test doubles) need not provide one.
    fn emit_permission_asked(&self, _tool: String, _scope: String, _request_id: Option<String>) {}

    /// Emit a wake-prompt context ack surfaced by the ACP wake-accept path.
    /// Default no-op so non-ACP impls (test doubles) need not provide one.
    fn emit_context_injected(&self, _actor: String, _summary: Option<String>) {}

    /// Emit the stop reason the agent reported for a finished prompt turn.
    /// Default no-op so non-ACP impls (test doubles) need not provide one.
    fn emit_turn_ended(&self, _stop_reason: String) {}
}

/// Supervisor for an ACP session.
///
/// Tracks process group, watchdog state, in-flight agent-to-daemon calls, and
/// daemon-to-agent pending requests.
pub struct AcpSessionSupervisor {
    process: SupervisedProcess,
    config: SupervisionConfig,
    state: AtomicU64,
    in_flight_calls: AtomicU64,
    pending_requests: AtomicU64,
    shutting_down: AtomicBool,
    last_event_at: Mutex<Instant>,
    last_client_call_at: Mutex<Option<String>>,
    watchdog_notify: Notify,
    /// One-shot emitter slot. `OnceLock` is wait-free on the emit hot path
    /// and panic-free on attach contention; the prior `Mutex<Option<Arc>>`
    /// would have crashed the supervisor on a poisoned lock.
    event_emitter: OnceLock<Arc<dyn WatchdogEventEmitter>>,
    handshake: OnceLock<AcpAgentHandshake>,
    session_state: Mutex<Option<AcpAgentSessionState>>,
}

impl AcpSessionSupervisor {
    /// Create a supervisor for a spawned child.
    ///
    /// The watchdog starts Paused: an idle agent with no daemon-issued request
    /// awaiting a response is healthy, not a kill candidate.
    #[must_use]
    pub fn new(child: &Child, config: SupervisionConfig) -> Self {
        Self::with_process(SupervisedProcess::from_child(child), config)
    }

    /// Create a supervisor for a process the daemon may not have spawned.
    ///
    /// The watchdog, deadlines, and request accounting are indifferent to how
    /// the agent runs; only reaping and pid reporting read the process, so a
    /// remote transport can supply one it never owned.
    #[must_use]
    pub fn with_process(process: SupervisedProcess, config: SupervisionConfig) -> Self {
        Self {
            process,
            config,
            state: AtomicU64::new(state_to_u64(WatchdogState::Paused)),
            in_flight_calls: AtomicU64::new(0),
            pending_requests: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
            last_event_at: Mutex::new(Instant::now()),
            last_client_call_at: Mutex::new(None),
            watchdog_notify: Notify::new(),
            event_emitter: OnceLock::new(),
            handshake: OnceLock::new(),
            session_state: Mutex::new(None),
        }
    }

    /// Record the `initialize` exchange result. First write wins; a
    /// reconnect on the same process would re-run initialize against the
    /// same agent, so later identical writes are dropped silently.
    pub fn record_handshake(&self, handshake: AcpAgentHandshake) {
        let _ = self.handshake.set(handshake);
    }

    #[must_use]
    pub fn handshake(&self) -> Option<&AcpAgentHandshake> {
        self.handshake.get()
    }

    /// Mutate the live session state, initialising it on first use. The
    /// protocol layer owns the ACP-notification semantics; this only
    /// serialises access.
    ///
    /// # Panics
    /// Panics if the state mutex is poisoned.
    pub fn mutate_session_state(&self, mutate: impl FnOnce(&mut AcpAgentSessionState)) {
        let mut guard = self.session_state.lock().expect("session state lock");
        mutate(guard.get_or_insert_with(AcpAgentSessionState::default));
    }

    /// # Panics
    /// Panics if the state mutex is poisoned.
    #[must_use]
    pub fn session_state(&self) -> Option<AcpAgentSessionState> {
        self.session_state
            .lock()
            .expect("session state lock")
            .clone()
    }

    /// Attach a sink that receives watchdog state transitions.
    ///
    /// One-shot per supervisor lifetime. `spawn_receive_loop` calls this
    /// exactly once. A second call is a programming error (the supervisor
    /// would keep emitting to the original sink while the caller assumed the
    /// new one took effect); we surface it via `debug_assert!` in test/dev
    /// builds and warn in release. If a future reconnect path needs to
    /// re-attach, replace `OnceLock` with `ArcSwap` rather than relaxing
    /// this invariant silently.
    pub fn attach_event_emitter(&self, emitter: Arc<dyn WatchdogEventEmitter>) {
        if self.event_emitter.set(emitter).is_err() {
            Self::warn_duplicate_event_emitter_attach();
        }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn warn_duplicate_event_emitter_attach() {
        debug_assert!(
            false,
            "attach_event_emitter called twice on the same supervisor; this is a programming error",
        );
        warn!(
            "attach_event_emitter called twice; second emitter ignored, supervisor keeps emitting to first sink",
        );
    }

    fn emit_transition(&self, from: WatchdogState, to: WatchdogState, reason: Option<&str>) {
        if let Some(emitter) = self.event_emitter.get() {
            emitter.emit_state(from, to, reason);
        }
    }

    /// Borrow the attached event emitter so external producers (e.g. the
    /// wake-accept path emitting `ContextInjected`) can publish synthetic
    /// events on the same per-session channel the supervisor uses for
    /// watchdog transitions. Returns `None` if no emitter is attached.
    #[must_use]
    pub fn event_emitter(&self) -> Option<&Arc<dyn WatchdogEventEmitter>> {
        self.event_emitter.get()
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
    ///
    /// # Panics
    /// Panics if the last-client-call mutex is poisoned.
    pub fn enter_client_call(&self) -> ClientCallGuard<'_> {
        self.enter_client_call_with_reason(None)
    }

    /// Acquire a client-call guard with a timeline reason. While held, the
    /// watchdog is paused.
    ///
    /// # Panics
    /// Panics if the last-client-call mutex is poisoned.
    pub fn enter_client_call_with_reason(
        &self,
        reason: Option<&'static str>,
    ) -> ClientCallGuard<'_> {
        *self
            .last_client_call_at
            .lock()
            .expect("last client call lock") = Some(utc_now());
        self.in_flight_calls.fetch_add(1, Ordering::SeqCst);
        self.update_watchdog_state(reason);
        ClientCallGuard {
            supervisor: self,
            reason,
        }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn exit_client_call(&self, reason: Option<&'static str>) {
        let result = self
            .in_flight_calls
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1));
        if result.is_err() {
            warn!("exit_client_call without matching enter; counter already at 0");
        }
        self.update_watchdog_state(reason);
        self.watchdog_notify.notify_one();
    }

    fn update_watchdog_state(&self, reason: Option<&str>) {
        // compare_exchange loop so concurrent enter/exit calls cannot interleave
        // a load+store window and produce duplicate or wrong-from emits. Only
        // the thread that wins the swap emits the transition.
        loop {
            let current_u64 = self.state.load(Ordering::SeqCst);
            let current = u64_to_state(current_u64);
            if current == WatchdogState::Fired || current == WatchdogState::Done {
                return;
            }
            let in_flight = self.in_flight_calls.load(Ordering::SeqCst);
            let pending = self.pending_requests.load(Ordering::SeqCst);
            let new_state = if in_flight == 0 && pending > 0 {
                WatchdogState::Active
            } else {
                WatchdogState::Paused
            };
            if new_state == current {
                return;
            }
            if self
                .state
                .compare_exchange(
                    current_u64,
                    state_to_u64(new_state),
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                )
                .is_ok()
            {
                self.emit_transition(current, new_state, reason);
                return;
            }
        }
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

    /// Number of daemon-issued requests awaiting an agent response.
    #[must_use]
    pub fn pending_request_count(&self) -> u64 {
        self.pending_requests.load(Ordering::SeqCst)
    }

    /// Acquire a pending-request guard. While held, the watchdog runs only if
    /// the agent has not produced events for `watchdog_timeout`. Last-event
    /// timestamp resets on entry so each daemon-issued request gets a fresh
    /// silence budget.
    ///
    /// # Panics
    /// Panics if the last-event mutex is poisoned.
    pub fn enter_pending_request(&self) -> PendingRequestGuard<'_> {
        self.enter_pending_request_with_reason(None)
    }

    /// Acquire a pending-request guard with a timeline reason.
    ///
    /// # Panics
    /// Panics if the last-event mutex is poisoned.
    pub fn enter_pending_request_with_reason(
        &self,
        reason: Option<&'static str>,
    ) -> PendingRequestGuard<'_> {
        *self.last_event_at.lock().unwrap() = Instant::now();
        self.pending_requests.fetch_add(1, Ordering::SeqCst);
        self.update_watchdog_state(reason);
        self.watchdog_notify.notify_one();
        PendingRequestGuard {
            supervisor: self,
            reason,
        }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn exit_pending_request(&self, reason: Option<&'static str>) {
        let result = self
            .pending_requests
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1));
        if result.is_err() {
            warn!("exit_pending_request without matching enter; counter already at 0");
        }
        self.update_watchdog_state(reason);
        self.watchdog_notify.notify_one();
    }

    /// Last time an agent-initiated client call began.
    ///
    /// # Panics
    /// Panics if the last-client-call mutex is poisoned.
    #[must_use]
    pub fn last_client_call_at(&self) -> Option<String> {
        self.last_client_call_at
            .lock()
            .expect("last client call lock")
            .clone()
    }

    /// Process group id.
    #[must_use]
    pub const fn pgid(&self) -> i32 {
        self.process.process_group()
    }

    /// Process id.
    #[must_use]
    pub const fn pid(&self) -> u32 {
        self.process.pid()
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
        let previous = self
            .state
            .swap(state_to_u64(WatchdogState::Fired), Ordering::SeqCst);
        let from = u64_to_state(previous);
        if from != WatchdogState::Fired {
            self.emit_transition(from, WatchdogState::Fired, Some("watchdog timeout"));
        }
    }

    /// Mark session as done.
    pub fn mark_done(&self) {
        let previous = self
            .state
            .swap(state_to_u64(WatchdogState::Done), Ordering::SeqCst);
        let from = u64_to_state(previous);
        self.watchdog_notify.notify_one();
        if from != WatchdogState::Done {
            self.emit_transition(from, WatchdogState::Done, Some("session complete"));
        }
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

#[cfg(all(test, feature = "daemon-runtime"))]
mod tests;
