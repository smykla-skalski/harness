//! Detect and evict orphaned codex `app-server` processes that pin the
//! bridge listening port across unclean bridge shutdowns.
//!
//! When the bridge dies on a signal before its drop chain runs, the
//! codex child gets reparented to launchd (`PPID == 1`). The codex stays
//! bound to the port and blocks every subsequent `bridge start` with
//! "Address already in use". This module owns the recovery path:
//!
//! 1. Bind-probe the port. Free → return early.
//! 2. Probe `/readyz` and shell out to `lsof` to identify the listener.
//! 3. Refuse if the listener is not an orphaned codex matching the
//!    requested binary - the operator gets a structured error with the
//!    PID instead of a silent kill of an unrelated process.
//! 4. Otherwise SIGTERM (then SIGKILL after a short grace) the orphan
//!    and re-bind to confirm the port is free.
//!
//! This recovery path is also the safety net for the SIGTERM-mid-spawn
//! window: while [`super::runtime::spawn_codex_process`] is waiting for
//! the new child to become ready, the child has not yet been registered
//! with [`super::server::BridgeServer`], so the signal-handler cleanup
//! cannot reach it. If the bridge dies in that window the codex still
//! escapes to launchd; the next `bridge start` evicts it here.

use std::io;
use std::net::TcpListener;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;

use super::runtime::probe_codex_readiness;
use super::types::CODEX_READY_PROBE_TIMEOUT;

const SIGTERM_GRACE: Duration = Duration::from_secs(3);
const REBIND_RETRY_INTERVAL: Duration = Duration::from_millis(100);
const REBIND_RETRY_BUDGET: Duration = Duration::from_secs(5);
const SHELLOUT_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug)]
pub(super) struct StaleCodex {
    pub(super) pid: i32,
    pub(super) ppid: i32,
    pub(super) command: String,
}

/// Bind-probe `port`; on conflict try to evict an orphaned codex that
/// matches `expected_binary`. Returns the conflict reason on failure so
/// the caller can surface it through `CliError`.
pub(super) fn ensure_codex_port_available(port: u16, expected_binary: &Path) -> Result<(), String> {
    if try_bind(port).is_ok() {
        return Ok(());
    }

    let endpoint = format!("ws://127.0.0.1:{port}");
    let listener_is_codex = probe_codex_readiness(&endpoint, CODEX_READY_PROBE_TIMEOUT).is_ok();
    let Some(stale) = detect_listener(port) else {
        return Err(format!(
            "127.0.0.1:{port} is unavailable and `lsof` could not identify the listener; \
             try `lsof -nP -iTCP:{port} -sTCP:LISTEN` and stop the holder manually"
        ));
    };
    if !listener_is_codex {
        return Err(format!(
            "127.0.0.1:{port} is held by pid {} (parent pid {}, command: {}) and does not \
             respond as a codex app-server; stop it manually with `kill {}` before retrying",
            stale.pid, stale.ppid, stale.command, stale.pid
        ));
    }
    if stale.ppid != 1 {
        return Err(format!(
            "127.0.0.1:{port} is held by codex pid {} (parent pid {}, command: {}); refusing to \
             evict a non-orphan listener - the parent process owns its lifecycle, stop the parent \
             instead of the codex",
            stale.pid, stale.ppid, stale.command
        ));
    }
    if !command_matches_binary(&stale.command, expected_binary) {
        return Err(format!(
            "127.0.0.1:{port} is held by orphan codex pid {} (command: {}) which does not match \
             expected binary {}; this is an orphan from a previous bridge crash but uses a \
             different codex install - stop it manually with `kill {}` before retrying",
            stale.pid,
            stale.command,
            expected_binary.display(),
            stale.pid,
        ));
    }

    tracing::warn!(
        port,
        pid = stale.pid,
        command = %stale.command,
        "evicting orphan codex app-server (orphan from previous bridge crash) holding bridge port"
    );
    evict(stale.pid)?;
    wait_for_port_free(port)
}

fn try_bind(port: u16) -> Result<(), String> {
    TcpListener::bind(("127.0.0.1", port))
        .map(drop)
        .map_err(|error| format!("127.0.0.1:{port} is unavailable: {error}"))
}

fn wait_for_port_free(port: u16) -> Result<(), String> {
    let started = Instant::now();
    loop {
        if try_bind(port).is_ok() {
            return Ok(());
        }
        if started.elapsed() >= REBIND_RETRY_BUDGET {
            return Err(format!(
                "127.0.0.1:{port} still unavailable after evicting stale codex"
            ));
        }
        thread::sleep(REBIND_RETRY_INTERVAL);
    }
}

fn evict(pid: i32) -> Result<(), String> {
    let target = Pid::from_raw(pid);
    if let Err(error) = kill(target, Signal::SIGTERM) {
        return Err(format!("SIGTERM pid {pid}: {error}"));
    }
    let deadline = Instant::now() + SIGTERM_GRACE;
    while Instant::now() < deadline {
        if kill(target, None).is_err() {
            return Ok(());
        }
        thread::sleep(REBIND_RETRY_INTERVAL);
    }
    if kill(target, Signal::SIGKILL).is_err() && kill(target, None).is_ok() {
        return Err(format!("pid {pid} survived SIGKILL"));
    }
    Ok(())
}

fn detect_listener(port: u16) -> Option<StaleCodex> {
    let listener_pid = lsof_listening_pid(port)?;
    let (parent_pid, command) = ps_ppid_and_command(listener_pid)?;
    Some(StaleCodex {
        pid: listener_pid,
        ppid: parent_pid,
        command,
    })
}

fn lsof_listening_pid(port: u16) -> Option<i32> {
    let stdout = run_with_timeout(
        Command::new("lsof").args([
            "-nP",
            "-iTCP",
            &format!(":{port}"),
            "-sTCP:LISTEN",
            "-t",
        ]),
        SHELLOUT_TIMEOUT,
    )?;
    parse_first_pid(&stdout)
}

fn parse_first_pid(stdout: &str) -> Option<i32> {
    stdout
        .lines().find_map(|line| line.trim().parse::<i32>().ok())
}

fn ps_ppid_and_command(pid: i32) -> Option<(i32, String)> {
    let stdout = run_with_timeout(
        Command::new("ps").args(["-o", "ppid=,command=", "-p", &pid.to_string()]),
        SHELLOUT_TIMEOUT,
    )?;
    parse_ppid_and_command(&stdout)
}

/// Spawn `command`, capture stdout, and bound the wait-for-exit by
/// `timeout`. Returns `None` if the process fails to spawn, exits with a
/// non-zero status, exceeds the timeout, or its stdout is not UTF-8.
///
/// Bounded shellouts matter on the bridge-start path: a wedged `lsof`
/// (which can happen on macOS hosts under EDR / filesystem stalls)
/// would otherwise block every `bridge start` indefinitely with no
/// diagnostic.
fn run_with_timeout(command: &mut Command, timeout: Duration) -> Option<String> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(io::read_to_string(stdout));
    });
    let Some(exit_status) = wait_with_timeout(&mut child, timeout) else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    if !exit_status.success() {
        return None;
    }
    receiver.recv().ok()?.ok()
}

fn wait_with_timeout(child: &mut Child, timeout: Duration) -> Option<ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    return None;
                }
                thread::sleep(Duration::from_millis(25));
            }
            Err(_) => return None,
        }
    }
}

fn parse_ppid_and_command(line: &str) -> Option<(i32, String)> {
    let trimmed = line.trim();
    let mut parts = trimmed.splitn(2, char::is_whitespace);
    let ppid = parts.next()?.trim().parse::<i32>().ok()?;
    let command = parts.next()?.trim().to_string();
    if command.is_empty() {
        return None;
    }
    Some((ppid, command))
}

/// Decide whether the `argv0` token in `command` resolves to
/// `expected_binary`.
///
/// Matching is conservative: extract the first whitespace-delimited
/// token from `ps -o command=` output and accept it only when its full
/// string equals the expected path, OR the basename of that token
/// equals the basename of the expected path. Heuristic substring
/// matches (`starts_with` / `ends_with`) are intentionally rejected
/// because this decision feeds an automatic SIGTERM at `bridge start`
/// and the council flagged that variants like `codex-experimental`
/// could otherwise be matched against `codex`.
fn command_matches_binary(command: &str, expected_binary: &Path) -> bool {
    let Some(argv0) = command.split_whitespace().next() else {
        return false;
    };
    let expected_full = expected_binary.to_string_lossy();
    if argv0 == expected_full.as_ref() {
        return true;
    }
    let argv0_basename = Path::new(argv0).file_name();
    let expected_basename = expected_binary.file_name();
    matches!((argv0_basename, expected_basename), (Some(a), Some(b)) if a == b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_first_pid_picks_first_numeric_line() {
        assert_eq!(parse_first_pid("12345\n67890\n"), Some(12345));
    }

    #[test]
    fn parse_first_pid_ignores_blank_lines() {
        assert_eq!(parse_first_pid("\n\n42\n"), Some(42));
    }

    #[test]
    fn parse_first_pid_rejects_non_numeric() {
        assert_eq!(parse_first_pid("xyz\n"), None);
    }

    #[test]
    fn parse_ppid_and_command_handles_homebrew_path() {
        let parsed =
            parse_ppid_and_command("    1 /opt/homebrew/bin/codex app-server --listen ws://...\n");
        assert_eq!(
            parsed,
            Some((
                1,
                "/opt/homebrew/bin/codex app-server --listen ws://...".to_string()
            ))
        );
    }

    #[test]
    fn parse_ppid_and_command_rejects_missing_command() {
        assert_eq!(parse_ppid_and_command("    1\n"), None);
    }

    #[test]
    fn command_matches_binary_exact_argv0() {
        assert!(command_matches_binary(
            "/opt/homebrew/bin/codex app-server",
            Path::new("/opt/homebrew/bin/codex")
        ));
    }

    #[test]
    fn command_matches_binary_basename_match() {
        assert!(command_matches_binary(
            "codex app-server",
            Path::new("/usr/local/bin/codex")
        ));
    }

    #[test]
    fn command_matches_binary_rejects_unrelated_command() {
        assert!(!command_matches_binary(
            "/usr/bin/python3 -m foo",
            Path::new("/opt/homebrew/bin/codex")
        ));
    }

    #[test]
    fn command_matches_binary_rejects_sibling_binary_with_codex_prefix() {
        // Council muratori/tef flagged: `starts_with` would match
        // `/opt/homebrew/bin/codex-experimental` against `codex`.
        // Token equality on argv0 must reject this.
        assert!(!command_matches_binary(
            "/opt/homebrew/bin/codex-experimental app-server",
            Path::new("/opt/homebrew/bin/codex"),
        ));
    }

    #[test]
    fn command_matches_binary_rejects_sibling_basename() {
        // `not-codex` ends with `codex`; the prior heuristic accepted
        // this. Strict basename equality must reject it.
        assert!(!command_matches_binary(
            "/usr/local/bin/not-codex app-server",
            Path::new("/opt/homebrew/bin/codex"),
        ));
    }

    #[test]
    fn command_matches_binary_handles_empty_command() {
        assert!(!command_matches_binary("", Path::new("/usr/bin/codex")));
    }
}
