//! Tests for ACP session supervision.

use std::fs;
use std::path::Path;
use std::process::{Child, Command};
use std::sync::Arc;
use std::time::{Duration, Instant};

use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;

use super::*;

fn spawn_sleep_child() -> Child {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let mut cmd = Command::new("sleep");
        cmd.arg("60");
        cmd.process_group(0);
        cmd.spawn().expect("spawn sleep")
    }
    #[cfg(not(unix))]
    {
        Command::new("timeout")
            .args(["/t", "60"])
            .spawn()
            .expect("spawn timeout")
    }
}

#[cfg(unix)]
fn wait_for_file_marker(path: &Path, marker: &str) {
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline {
        if fs::read_to_string(path).is_ok_and(|content| content.contains(marker)) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("expected marker '{marker}' in {}", path.display());
}

#[test]
fn supervisor_starts_paused() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);
    assert_eq!(supervisor.in_flight_call_count(), 0);
    assert_eq!(supervisor.pending_request_count(), 0);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[test]
fn pending_request_guard_activates_watchdog() {
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

#[test]
fn client_call_guard_pauses_watchdog() {
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

#[test]
fn watchdog_does_not_fire_while_paused() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    let _pending = supervisor.enter_pending_request();
    let _guard = supervisor.enter_client_call();
    std::thread::sleep(Duration::from_millis(50));

    assert!(!supervisor.should_fire_watchdog());
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[test]
fn idle_supervisor_does_not_fire_watchdog() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    std::thread::sleep(Duration::from_millis(50));

    assert!(
        !supervisor.should_fire_watchdog(),
        "idle agent with no pending request must not fire watchdog"
    );
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[test]
fn watchdog_fires_after_timeout() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);
    let _pending = supervisor.enter_pending_request();

    std::thread::sleep(Duration::from_millis(50));

    assert!(supervisor.should_fire_watchdog());
    supervisor.mark_watchdog_fired();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Fired);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test]
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

#[tokio::test]
async fn watchdog_loop_does_not_fire_for_idle_agent() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(20);

    let child = spawn_sleep_child();
    let supervisor = Arc::new(AcpSessionSupervisor::new(&child, config));
    let task = tokio::spawn(watchdog_loop(Arc::clone(&supervisor)));

    let timed_out = tokio::time::timeout(Duration::from_millis(100), &mut Box::pin(async {})).await;
    assert!(timed_out.is_ok());
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        !task.is_finished(),
        "watchdog must keep idle agents alive indefinitely"
    );
    supervisor.mark_done();
    let reason = tokio::time::timeout(Duration::from_millis(100), task)
        .await
        .expect("watchdog should wake on done")
        .expect("watchdog task should not panic");
    assert_eq!(reason, None);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[tokio::test]
async fn watchdog_loop_returns_none_when_session_is_done() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_mins(1);

    let child = spawn_sleep_child();
    let supervisor = Arc::new(AcpSessionSupervisor::new(&child, config));
    let task = tokio::spawn(watchdog_loop(Arc::clone(&supervisor)));

    supervisor.mark_done();

    let reason = tokio::time::timeout(Duration::from_millis(100), task)
        .await
        .expect("watchdog should wake after done")
        .expect("watchdog task should not panic");
    assert_eq!(reason, None);
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Done);

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}

#[test]
fn record_event_resets_watchdog() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(100);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    std::thread::sleep(Duration::from_millis(60));
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

    let status = child.try_wait().expect("try_wait after kill");
    assert!(status.is_some(), "child should be dead");
}

#[test]
#[cfg(unix)]
fn kill_process_group_escalates_when_child_traps_sigterm() {
    use std::os::unix::process::{CommandExt, ExitStatusExt};

    let temp = tempfile::tempdir().expect("tempdir");
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
    let mut child = command.spawn().expect("spawn trap child");
    wait_for_file_marker(&log_path, "ready");

    let pgid = child.id().cast_signed();
    kill_process_group(pgid, &mut child);

    let status = child.try_wait().expect("try_wait after kill");
    let status = status.expect("child should be dead");
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

#[test]
fn begin_shutdown_returns_true_once() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());

    assert!(supervisor.begin_shutdown());
    assert!(!supervisor.begin_shutdown());
    assert!(supervisor.is_shutting_down());

    #[cfg(unix)]
    let _ = killpg(Pid::from_raw(supervisor.pgid()), Signal::SIGKILL);
}
