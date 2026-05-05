use std::sync::Arc;

#[cfg(unix)]
use nix::sys::signal::{Signal, killpg};
#[cfg(unix)]
use nix::unistd::Pid;
use tokio::sync::mpsc;

use crate::agents::acp::connection::SupervisorEventSink;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::timeline::{TimelinePayloadScope, conversation_entry};

use super::super::{AcpSessionSupervisor, SupervisionConfig, WatchdogEventEmitter, WatchdogState};
use super::support::spawn_sleep_child;

#[derive(Default)]
struct RecordingEmitter {
    transitions: std::sync::Mutex<Vec<(WatchdogState, WatchdogState, Option<String>)>>,
}

impl RecordingEmitter {
    fn snapshot(&self) -> Vec<(WatchdogState, WatchdogState, Option<String>)> {
        self.transitions.lock().expect("recording lock").clone()
    }
}

impl WatchdogEventEmitter for RecordingEmitter {
    fn emit_state(&self, from: WatchdogState, to: WatchdogState, reason: Option<&str>) {
        self.transitions.lock().expect("recording lock").push((
            from,
            to,
            reason.map(str::to_string),
        ));
    }
}

#[tokio::test(start_paused = true)]
async fn pending_request_guard_emits_paused_to_active() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    let emitter = Arc::new(RecordingEmitter::default());
    supervisor.attach_event_emitter(emitter.clone());

    {
        let _pending = supervisor.enter_pending_request();
        assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);
    }
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);

    let snapshot = emitter.snapshot();
    assert_eq!(
        snapshot.len(),
        2,
        "expected paused->active and active->paused"
    );
    assert_eq!(snapshot[0].0, WatchdogState::Paused);
    assert_eq!(snapshot[0].1, WatchdogState::Active);
    assert_eq!(snapshot[1].0, WatchdogState::Active);
    assert_eq!(snapshot[1].1, WatchdogState::Paused);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn pending_request_guard_emits_reason() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    let emitter = Arc::new(RecordingEmitter::default());
    supervisor.attach_event_emitter(emitter.clone());

    {
        let _pending = supervisor.enter_pending_request_with_reason(Some("session/new"));
        assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);
    }
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);

    let snapshot = emitter.snapshot();
    assert_eq!(snapshot.len(), 2);
    assert_eq!(snapshot[0].2.as_deref(), Some("session/new"));
    assert_eq!(snapshot[1].2.as_deref(), Some("session/new"));

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn mark_watchdog_fired_emits_terminal_transition() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    let emitter = Arc::new(RecordingEmitter::default());
    supervisor.attach_event_emitter(emitter.clone());

    supervisor.mark_watchdog_fired();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Fired);

    supervisor.mark_watchdog_fired();
    assert_eq!(
        emitter.snapshot().len(),
        1,
        "second mark_fired must not double-emit"
    );

    let (from, to, reason) = emitter.snapshot().into_iter().next().expect("transition");
    assert_eq!(from, WatchdogState::Paused);
    assert_eq!(to, WatchdogState::Fired);
    assert_eq!(reason.as_deref(), Some("watchdog timeout"));

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn mark_done_emits_done_transition() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    let emitter = Arc::new(RecordingEmitter::default());
    supervisor.attach_event_emitter(emitter.clone());

    supervisor.mark_done();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Done);

    supervisor.mark_done();
    assert_eq!(
        emitter.snapshot().len(),
        1,
        "second mark_done must not double-emit"
    );

    let (from, to, reason) = emitter.snapshot().into_iter().next().expect("transition");
    assert_eq!(from, WatchdogState::Paused);
    assert_eq!(to, WatchdogState::Done);
    assert_eq!(reason.as_deref(), Some("session complete"));

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn update_watchdog_state_does_not_emit_when_unchanged() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    let emitter = Arc::new(RecordingEmitter::default());
    supervisor.attach_event_emitter(emitter.clone());

    let _client_call = supervisor.enter_client_call();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
    assert!(emitter.snapshot().is_empty(), "no transition expected");

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn supervisor_event_sink_carries_terminal_transition_through_mpsc() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());

    let (tx, mut rx) = mpsc::channel(8);
    let sink = Arc::new(SupervisorEventSink::new(
        tx,
        "agent-test".to_string(),
        "session-test".to_string(),
    ));
    supervisor.attach_event_emitter(sink);

    supervisor.mark_watchdog_fired();

    let batch = rx.recv().await.expect("supervisor event batch");
    assert_eq!(batch.session_id, "session-test");
    assert_eq!(batch.raw_count, 0, "synthetic supervisor batch");
    assert_eq!(batch.events.len(), 1);
    let event = &batch.events[0];
    assert_eq!(event.agent, "agent-test");
    let supervisor_sequence = event.sequence;
    match &event.kind {
        ConversationEventKind::WatchdogState { from, to, reason } => {
            assert_eq!(from, "paused");
            assert_eq!(to, "fired");
            assert_eq!(reason.as_deref(), Some("watchdog timeout"));
        }
        other => panic!("unexpected kind: {other:?}"),
    }

    let supervisor_entry = conversation_entry(
        "session-test",
        "agent-test",
        "acp",
        event,
        TimelinePayloadScope::Full,
    )
    .expect("conversation_entry should succeed for WatchdogState")
    .expect("WatchdogState maps to Some(TimelineEntry)");
    assert_eq!(
        supervisor_entry.entry_id,
        format!("acp-agent-test-agent_watchdog_state-{supervisor_sequence}"),
        "watchdog entry_id encodes (agent, kind, sequence)",
    );
    assert_eq!(supervisor_entry.kind, "agent_watchdog_state");
    assert_eq!(
        supervisor_entry.summary,
        "agent-test watchdog paused -> fired (watchdog timeout)"
    );

    let transcript_collision = ConversationEvent {
        timestamp: Some("2026-05-04T23:00:00Z".to_string()),
        sequence: supervisor_sequence,
        kind: ConversationEventKind::AssistantText {
            content: "hello".to_string(),
        },
        agent: "agent-test".to_string(),
        session_id: "session-test".to_string(),
    };
    let transcript_entry = conversation_entry(
        "session-test",
        "agent-test",
        "acp",
        &transcript_collision,
        TimelinePayloadScope::Full,
    )
    .expect("conversation_entry should succeed for AssistantText")
    .expect("AssistantText maps to Some(TimelineEntry)");
    assert_ne!(
        supervisor_entry.entry_id, transcript_entry.entry_id,
        "disjoint entry_kind keeps the (kind, sequence) space collision-free even when sequences match",
    );

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn supervisor_event_sink_drops_silently_when_channel_full() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());

    let (tx, mut rx) = mpsc::channel(1);
    let sink = Arc::new(SupervisorEventSink::new(
        tx,
        "agent-test".to_string(),
        "session-test".to_string(),
    ));
    supervisor.attach_event_emitter(sink);

    {
        let _pending = supervisor.enter_pending_request();
    }
    supervisor.mark_watchdog_fired();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Fired);

    let mut delivered = Vec::new();
    while let Ok(batch) = rx.try_recv() {
        delivered.push(batch);
    }
    assert_eq!(
        delivered.len(),
        1,
        "channel buffer of 1 admits exactly one batch; subsequent transitions drop",
    );
    assert_eq!(delivered[0].raw_count, 0);
    match &delivered[0].events[0].kind {
        ConversationEventKind::WatchdogState { from, to, .. } => {
            assert_eq!(from, "paused");
            assert_eq!(to, "active");
        }
        other => panic!("unexpected first batch kind: {other:?}"),
    }

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[test]
fn supervisor_event_sink_emits_context_injected_with_actor_and_summary() {
    let (tx, mut rx) = mpsc::channel(8);
    let sink = SupervisorEventSink::new(tx, "agent-test".to_string(), "session-test".to_string());

    sink.emit_context_injected("acp".to_string(), Some("wake prompt accepted".into()));

    let batch = rx
        .try_recv()
        .expect("context_injected batch must be admitted");
    assert_eq!(batch.events.len(), 1);
    assert_eq!(batch.session_id, "session-test");
    assert_eq!(batch.raw_count, 0);
    match &batch.events[0].kind {
        ConversationEventKind::ContextInjected { actor, summary } => {
            assert_eq!(actor, "acp");
            assert_eq!(summary.as_deref(), Some("wake prompt accepted"));
        }
        other => panic!("unexpected kind: {other:?}"),
    }
}

#[test]
fn supervisor_event_sink_emits_context_injected_without_summary() {
    let (tx, mut rx) = mpsc::channel(8);
    let sink = SupervisorEventSink::new(tx, "agent-test".to_string(), "session-test".to_string());

    sink.emit_context_injected("acp".to_string(), None);

    let batch = rx
        .try_recv()
        .expect("context_injected batch must be admitted");
    match &batch.events[0].kind {
        ConversationEventKind::ContextInjected { actor, summary } => {
            assert_eq!(actor, "acp");
            assert!(summary.is_none(), "summary must be omitted when None");
        }
        other => panic!("unexpected kind: {other:?}"),
    }
}
