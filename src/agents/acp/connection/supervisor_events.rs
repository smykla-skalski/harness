use std::sync::atomic::{AtomicU64, Ordering};

use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::agents::acp::supervision::{WatchdogEventEmitter, WatchdogState};
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};

use super::EventBatch;

/// Sink that materialises supervisor watchdog transitions into the same
/// conversation event stream used by the ACP receive loop.
///
/// Each emit produces a single-event `EventBatch` with `raw_count: 0` so
/// downstream consumers can distinguish synthetic supervisor events from
/// agent stdout.
///
/// **Channel scope:** the `mpsc::Sender` passed to `new` is the per-session
/// channel created by `spawn_receive_loop`. There is one sink per session,
/// one channel per session, so a saturating burst on session A's channel
/// cannot starve session B's supervisor signal. A dropped Fired/Done batch
/// here means *this* session's UI lost the terminal transition; the operator
/// must read the daemon log to detect that case (the `warn!` line names the
/// `session_id` explicitly).
///
/// **Sequence-space contract:** `SupervisorEventSink::sequence` is a
/// SEPARATE counter from the receive loop's transcript sequence. Both
/// counters start at 0 and increment independently. Downstream consumers
/// MUST key on `(entry_kind, sequence)` and never on `sequence` alone.
/// `entries.rs::conversation_entry` already encodes this: the synthesized
/// `entry_id` is `format!("{runtime}-{agent_id}-{entry_kind}-{sequence}")`,
/// where `entry_kind` includes `agent_watchdog_state` for supervisor events
/// and disjoint kind strings for transcript events, so collisions are
/// impossible by construction.
pub struct SupervisorEventSink {
    tx: mpsc::Sender<EventBatch>,
    acp_id: String,
    agent_name: String,
    session_id: String,
    /// Synthetic-event sequence space, disjoint from the receive loop's
    /// transcript sequence. See type-level doc for the contract.
    sequence: AtomicU64,
}

impl SupervisorEventSink {
    /// Build a sink bound to the supplied event channel and identity.
    #[must_use]
    pub fn new(
        tx: mpsc::Sender<EventBatch>,
        acp_id: String,
        agent_name: String,
        session_id: String,
    ) -> Self {
        Self {
            tx,
            acp_id,
            agent_name,
            session_id,
            sequence: AtomicU64::new(0),
        }
    }

    /// Emit a synthetic `PermissionAsked` event into the per-session channel.
    ///
    /// Producer site: `HarnessAcpClient::handle_request_permission` calls this
    /// on every permission gate, regardless of mode. The variant is never
    /// terminal (the watchdog stays alive while the user is deciding).
    pub fn emit_permission_asked(&self, tool: String, scope: String, request_id: Option<String>) {
        self.emit(
            ConversationEventKind::PermissionAsked {
                tool,
                scope,
                request_id,
            },
            false,
        );
    }

    /// Emit a synthetic `ContextInjected` event into the per-session channel.
    ///
    /// Producer site: `daemon::agent_acp::manager::session_access::record_wake_accept`
    /// calls this once the wake-prompt ack lands, so the timeline shows that
    /// the dispatched context was received. Never terminal.
    pub fn emit_context_injected(&self, actor: String, summary: Option<String>) {
        self.emit(
            ConversationEventKind::ContextInjected { actor, summary },
            false,
        );
    }

    /// Emit a synthetic `TurnEnded` event into the per-session channel.
    ///
    /// Producer site: `daemon::agent_acp::protocol::session_state` calls this
    /// when a `session/prompt` response lands, so the timeline shows why the
    /// turn stopped (notably a refusal). Never terminal: the session stays
    /// alive for the next prompt.
    pub fn emit_turn_ended(&self, stop_reason: String) {
        self.emit(ConversationEventKind::TurnEnded { stop_reason }, false);
    }

    fn emit(&self, kind: ConversationEventKind, terminal: bool) {
        let batch = self.synthetic_batch(kind);
        self.try_emit_batch(batch, terminal);
    }

    fn synthetic_batch(&self, kind: ConversationEventKind) -> EventBatch {
        let sequence = self.sequence.fetch_add(1, Ordering::SeqCst);
        let event = ConversationEvent {
            timestamp: Some(chrono::Utc::now().to_rfc3339()),
            sequence,
            kind,
            agent: self.agent_name.clone(),
            session_id: self.session_id.clone(),
        };

        EventBatch {
            acp_id: self.acp_id.clone(),
            session_id: self.session_id.clone(),
            events: vec![event],
            raw_count: 0,
        }
    }

    fn try_emit_batch(&self, batch: EventBatch, terminal: bool) {
        if let Err(err) = self.tx.try_send(batch) {
            self.log_dropped_batch(&err, terminal);
        }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn log_dropped_batch(&self, err: &mpsc::error::TrySendError<EventBatch>, terminal: bool) {
        if terminal {
            warn!(
                error = %err,
                session_id = %self.session_id,
                "supervisor event sink dropped TERMINAL watchdog batch (receiver full or closed)",
            );
        } else {
            debug!(error = %err, "supervisor event sink dropped batch (receiver full or closed)");
        }
    }
}

impl WatchdogEventEmitter for SupervisorEventSink {
    fn emit_state(&self, from: WatchdogState, to: WatchdogState, reason: Option<&str>) {
        let terminal = matches!(to, WatchdogState::Fired | WatchdogState::Done);
        self.emit(
            ConversationEventKind::WatchdogState {
                from: from.as_str().to_string(),
                to: to.as_str().to_string(),
                reason: reason.map(str::to_string),
            },
            terminal,
        );
    }

    fn emit_permission_asked(&self, tool: String, scope: String, request_id: Option<String>) {
        Self::emit_permission_asked(self, tool, scope, request_id);
    }

    fn emit_context_injected(&self, actor: String, summary: Option<String>) {
        Self::emit_context_injected(self, actor, summary);
    }

    fn emit_turn_ended(&self, stop_reason: String) {
        Self::emit_turn_ended(self, stop_reason);
    }
}
