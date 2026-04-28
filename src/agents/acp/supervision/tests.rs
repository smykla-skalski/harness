//! Tests for ACP session supervision.
#![allow(unsafe_code)]

use std::process::{Child, Command};
use std::time::Duration;

use super::*;

fn spawn_sleep_child() -> Child {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let mut cmd = Command::new("sleep");
        cmd.arg("60");
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
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

#[test]
fn supervisor_starts_active() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Active);
    assert_eq!(supervisor.in_flight_call_count(), 0);

    #[cfg(unix)]
    unsafe {
        libc::killpg(supervisor.pgid(), libc::SIGKILL);
    }
}

#[test]
fn client_call_guard_pauses_watchdog() {
    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, SupervisionConfig::default());

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
    unsafe {
        libc::killpg(supervisor.pgid(), libc::SIGKILL);
    }
}

#[test]
fn watchdog_does_not_fire_while_paused() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    let _guard = supervisor.enter_client_call();
    std::thread::sleep(Duration::from_millis(50));

    assert!(!supervisor.should_fire_watchdog());
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Paused);

    #[cfg(unix)]
    unsafe {
        libc::killpg(supervisor.pgid(), libc::SIGKILL);
    }
}

#[test]
fn watchdog_fires_after_timeout() {
    let mut config = SupervisionConfig::default();
    config.watchdog_timeout = Duration::from_millis(10);

    let child = spawn_sleep_child();
    let supervisor = AcpSessionSupervisor::new(&child, config);

    std::thread::sleep(Duration::from_millis(50));

    assert!(supervisor.should_fire_watchdog());
    supervisor.mark_watchdog_fired();
    assert_eq!(supervisor.watchdog_state(), WatchdogState::Fired);

    #[cfg(unix)]
    unsafe {
        libc::killpg(supervisor.pgid(), libc::SIGKILL);
    }
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
    unsafe {
        libc::killpg(supervisor.pgid(), libc::SIGKILL);
    }
}

#[test]
fn supervision_config_with_prompt_timeout() {
    let config = SupervisionConfig::default().with_prompt_timeout(Some(1200));
    assert_eq!(config.prompt_timeout, Duration::from_secs(1200));

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
    unsafe {
        libc::killpg(supervisor.pgid(), libc::SIGKILL);
    }
}
