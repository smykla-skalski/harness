use std::fs;
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

#[cfg(unix)]
use nix::sys::signal::{Signal, killpg};
#[cfg(unix)]
use nix::unistd::Pid;
use tokio::time::{advance, timeout};

use super::super::{
    AcpSessionSupervisor, DEFAULT_PROMPT_TIMEOUT, DaemonShutdownError, SupervisionConfig,
    WatchdogState, kill_process_group, watchdog_loop,
};
use super::support::{ok, spawn_sleep_child, wait_for_file_marker};
use crate::acp::client::DAEMON_SHUTDOWN;
use crate::kind::DisconnectReason;

fn watchdog_config(watchdog_timeout: Duration) -> SupervisionConfig {
    SupervisionConfig {
        watchdog_timeout,
        ..SupervisionConfig::default()
    }
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
    let config = watchdog_config(Duration::from_millis(10));

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
    let config = watchdog_config(Duration::from_millis(10));

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
    let config = watchdog_config(Duration::from_millis(10));

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
    let config = watchdog_config(Duration::from_millis(10));

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
    let config = watchdog_config(Duration::from_millis(20));

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
            timeout(Duration::from_millis(100), task).await,
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
    let config = watchdog_config(Duration::from_mins(1));

    let child = spawn_sleep_child();
    let supervisor = Arc::new(AcpSessionSupervisor::new(&child, config));
    let task = tokio::spawn(watchdog_loop(Arc::clone(&supervisor)));

    supervisor.mark_done();

    let reason = ok(
        ok(
            timeout(Duration::from_millis(100), task).await,
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
    let config = watchdog_config(Duration::from_millis(100));

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
#[cfg(unix)]
fn kill_process_group_terminates_descendant_after_leader_exits() {
    use std::os::unix::process::CommandExt;

    let temp = ok(tempfile::tempdir(), "tempdir");
    let pid_path = temp.path().join("descendant.pid");
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg("trap '' TERM; sleep 60 & echo $! > \"$HARNESS_TEST_PID_PATH\"")
        .env("HARNESS_TEST_PID_PATH", &pid_path);
    command.process_group(0);
    let mut child = ok(command.spawn(), "spawn leader");
    let pgid = child.id().cast_signed();
    wait_for_file_marker(&pid_path, "\n");
    let descendant_pid = ok(fs::read_to_string(&pid_path), "read descendant pid");
    let descendant_pid = ok(descendant_pid.trim().parse::<u32>(), "parse descendant pid");
    let _ = ok(child.wait(), "wait for leader");

    kill_process_group(pgid, &mut child);

    assert!(
        !process_is_running(descendant_pid),
        "descendant process should not be running"
    );
}

#[cfg(unix)]
fn process_is_running(pid: u32) -> bool {
    let output = ok(
        Command::new("/bin/ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output(),
        "inspect descendant process",
    );
    let state = String::from_utf8_lossy(&output.stdout);
    output.status.success() && !state.trim_start().starts_with('Z')
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
