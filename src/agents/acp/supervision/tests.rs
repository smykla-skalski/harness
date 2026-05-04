//! Tests for ACP session supervision.

use std::fs;
use std::path::Path;
use std::process::{Child, Command};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::time::advance;

use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;

use super::*;

#[track_caller]
fn ok<T, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> T {
    assert!(
        result.is_ok(),
        "{context}: unexpected Err({:?})",
        result.as_ref().err()
    );
    match result {
        Ok(value) => value,
        Err(error) => unreachable!("{context}: {error:?}"),
    }
}

fn spawn_sleep_child() -> Child {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let mut cmd = Command::new("sleep");
        cmd.arg("60");
        cmd.process_group(0);
        ok(cmd.spawn(), "spawn sleep")
    }
    #[cfg(not(unix))]
    {
        ok(
            Command::new("timeout").args(["/t", "60"]).spawn(),
            "spawn timeout",
        )
    }
}

#[cfg(unix)]
fn wait_for_file_marker(path: &Path, marker: &str) {
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut found = false;
    while Instant::now() < deadline {
        if fs::read_to_string(path).is_ok_and(|content| content.contains(marker)) {
            found = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(found, "expected marker '{marker}' in {}", path.display());
}

#[tokio::test(start_paused = true)]
async fn supervisor_starts_paused() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
    assert_eq!(supervisor.in_flight_call_count(), 0);
    assert_eq!(supervisor.pending_request_count(), 0);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn pending_request_guard_activates_watchdog() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());

    {
        let _pending = supervisor.enter_pending_request();
        assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);
        assert_eq!(supervisor.pending_request_count(), 1);

        let _pending2 = supervisor.enter_pending_request();
        assert_eq!(supervisor.pending_request_count(), 2);
    }

    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
    assert_eq!(supervisor.pending_request_count(), 0);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn client_call_guard_pauses_watchdog() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    let _pending = supervisor.enter_pending_request();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);

    {
        let _guard = supervisor.enter_client_call();
        assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
        assert_eq!(supervisor.in_flight_call_count(), 1);

        let _guard2 = supervisor.enter_client_call();
        assert_eq!(supervisor.in_flight_call_count(), 2);
    }

    assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);
    assert_eq!(supervisor.in_flight_call_count(), 0);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn watchdog_does_not_fire_while_paused() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    let _pending = supervisor.enter_pending_request();
    let _guard = supervisor.enter_client_call();
    advance(Duration::from_millis(50)).await;

    assert!(!supervisor.should_fire_watchdog());
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn idle_supervisor_does_not_fire_watchdog() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    advance(Duration::from_millis(50)).await;

    assert!(
        !supervisor.should_fire_watchdog(),
        "idle agent with no pending request must not fire watchdog"
    );
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn watchdog_fires_after_timeout() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);
    let _pending = supervisor.enter_pending_request();

    advance(Duration::from_millis(50)).await;

    assert!(supervisor.should_fire_watchdog());
    supervisor.mark_watchdog_fired();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Fired);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn watchdog_loop_returns_watchdog_fired_after_timeout() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = Arc::new(AcpSessionSupervisor::new(&child, config));
    let _pending = supervisor.enter_pending_request();

    let reason = watchdog_loop(Arc::clone(&supervisor)).await;
    assert_eq!(reason, Some(DisconnectReason::WatchdogFired));
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Fired);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn watchdog_loop_does_not_fire_for_idle_agent() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(20);

    let child = spawn_sleep_child();
    let supervisor = Arc::new(AcpSessionSupervisor::new(&child, config));
    let task = tokio::spawn(watchdog_loop(Arc::clone(&supervisor)));

    advance(Duration::from_millis(100)).await;
    assert!(
        !task.is_finished(),
        "watchdog must keep idle agents alive indefinitely"
    );
    supervisor.mark_done();
    let reason = ok(
        ok(
            tokio::time::timeout(Duration::from_millis(100), task).await,
            "watchdog should wake on done",
        ),
        "watchdog task should not panic",
    );
    assert_eq!(reason, None);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn watchdog_loop_returns_none_when_session_is_done() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_mins(1);

    let child = spawn_sleep_child();
    let supervisor = Arc::new(AcpSessionSupervisor::new(&child, config));
    let task = tokio::spawn(watchdog_loop(Arc::clone(&supervisor)));

    supervisor.mark_done();

    let reason = ok(
        ok(
            tokio::time::timeout(Duration::from_millis(100), task).await,
            "watchdog should wake after done",
        ),
        "watchdog task should not panic",
    );
    assert_eq!(reason, None);
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Done);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test(start_paused = true)]
async fn record_event_resets_watchdog() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(100);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    advance(Duration::from_millis(60)).await;
    assert!(supervisor.elapsed_since_last_event() >= Duration::from_millis(50));

    supervisor.record_event();
    assert!(supervisor.elapsed_since_last_event() < Duration::from_millis(20));

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[test]
fn supervision_config_with_prompt_timeout() {
    let config = SupervisionConfig::default().with_prompt_timeout(Some(1200));
    assert_eq!(config.prompt_timeout, Duration::from_mins(20));

    let config2 = SupervisionConfig::default().with_prompt_timeout(None);
    assert_eq!(config2.prompt_timeout, DEFAULT_PROMPT_TIMEOUT);
}

#[test]
#[cfg(unix)]
fn kill_process_group_terminates_child() {
    let mut child = spawn_sleep_child();
    let pgid = child.id().cast_signed();

    kill_process_group(pgid, &mut child);

    let status = ok(child.try_wait(), "try_wait after kill");
    assert!(status.is_some(), "child should be dead");
}

#[test]
#[cfg(unix)]
fn kill_process_group_escalates_when_child_traps_sigterm() {
    use std::os::unix::process::{CommandExt, ExitStatusExt};

    let temp = ok(tempfile::tempdir(), "tempdir");
    let log_path = temp.path().join("signal.log");
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg(
            "trap 'echo term >> \"$HARNESS_TEST_SIGNAL_LOG\"; while :; do sleep 1; done' TERM; \
             echo ready >> \"$HARNESS_TEST_SIGNAL_LOG\"; while :; do sleep 1; done",
        )
        .env("HARNESS_TEST_SIGNAL_LOG", &log_path);
    command.process_group(0);
    let mut child = ok(command.spawn(), "spawn trap child");
    wait_for_file_marker(&log_path, "ready");

    let pgid = child.id().cast_signed();
    kill_process_group(pgid, &mut child);

    let status = ok(child.try_wait(), "try_wait after kill");
    let Some(status) = status else {
        unreachable!("child should be dead");
    };
    assert_eq!(status.signal(), Some(Signal::SIGKILL as i32));
    wait_for_file_marker(&log_path, "term");
}

#[test]
fn daemon_shutdown_error_has_correct_code() {
    let err = DaemonShutdownError::new();
    assert_eq!(err.code, DAEMON_SHUTDOWN);
    assert!(err.message.contains("shutdown"));
}

#[test]
fn watchdog_state_as_str() {
    assert_eq!(WatchdogState::Active.as_str(), "active");
    assert_eq!(WatchdogState::Paused.as_str(), "paused");
    assert_eq!(WatchdogState::Fired.as_str(), "fired");
    assert_eq!(WatchdogState::Done.as_str(), "done");
}

#[tokio::test(start_paused = true)]
async fn begin_shutdown_returns_true_once() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());

    assert!(supervisor.begin_shutdown());
    assert!(!supervisor.begin_shutdown());
    assert!(supervisor.is_shutting_down());

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

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
        self.transitions
            .lock()
            .expect("recording lock")
            .push((from, to, reason.map(str::to_string)));
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
    assert_eq!(snapshot.len(), 2, "expected paused->active and active->paused");
    assert_eq!(snapshot[0].0, WatchdogState::Paused);
    assert_eq!(snapshot[0].1, WatchdogState::Active);
    assert_eq!(snapshot[1].0, WatchdogState::Active);
    assert_eq!(snapshot[1].1, WatchdogState::Paused);

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
    use crate::agents::acp::connection::SupervisorEventSink;
    use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
    use crate::daemon::timeline::{TimelinePayloadScope, conversation_entry};
    use tokio::sync::mpsc;

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

    // Drive the mapper end-to-end: a synthetic supervisor event with
    // sequence S must produce a watchdog timeline entry, and a transcript
    // event with the same numeric sequence S must NOT collide with it.
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
    use crate::agents::acp::connection::SupervisorEventSink;
    use crate::agents::runtime::event::ConversationEventKind;
    use tokio::sync::mpsc;

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());

    let (tx, mut rx) = mpsc::channel(1);
    let sink = Arc::new(SupervisorEventSink::new(
        tx,
        "agent-test".to_string(),
        "session-test".to_string(),
    ));
    supervisor.attach_event_emitter(sink);

    // First transition fits, second saturates the buffer, terminal third drops.
    {
        let _pending = supervisor.enter_pending_request();
    }
    supervisor.mark_watchdog_fired();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Fired);

    // Drain the receiver: only the first transition (Paused -> Active) fits.
    // The Active -> Paused on guard drop and the terminal Paused -> Fired
    // both hit a full channel and must be dropped without panicking.
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
