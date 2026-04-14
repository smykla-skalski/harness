//! Daemon root discovery and adoption.
//!
//! Short-lived `harness` CLI commands (notably the `harness bridge *` family)
//! must interact with whatever Harness daemon is currently running on the
//! host, regardless of which terminal they were launched from. The sandboxed
//! managed daemon writes its state into
//! `~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness/daemon`;
//! a plain terminal without `HARNESS_APP_GROUP_ID` defaults to
//! `~/.local/share/harness/daemon`. Without discovery, a user running
//! `harness bridge start` in a fresh terminal would land bridge state at
//! the XDG path while the sandboxed daemon watches the app group container,
//! and the bridge would never be picked up.
//!
//! [`adopt_running_daemon_root`] scans the plausible daemon roots, picks
//! the one whose [`crate::daemon::state::DAEMON_LOCK_FILE`] is currently
//! held (flock is immune to PID reuse and stale manifests), and installs a
//! process-local override via
//! [`crate::daemon::state::set_daemon_root_override`]. Every subsequent
//! [`crate::daemon::state::daemon_root`] call in this process resolves to
//! that path, so existing plumbing (`bridge_state_path`, `bridge_socket_path`,
//! etc.) automatically targets the running daemon without env mutation or
//! new argument plumbing.
//!
//! Candidate ordering respects user intent: if the caller has explicitly set
//! `HARNESS_DAEMON_DATA_HOME` or `HARNESS_APP_GROUP_ID`, that location is
//! probed first; only if it has no live daemon do we fall back to the
//! other plausible roots. This keeps the "I know what I am doing" escape
//! hatch working.

use std::path::PathBuf;

use crate::daemon::state;
use crate::daemon::transport::HARNESS_MONITOR_APP_GROUP_ID;
use crate::workspace::{harness_data_root, host_home_dir};

/// A candidate daemon root we might scan for a running daemon.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaemonLocation {
    /// Absolute filesystem path of this candidate's daemon root.
    pub root: PathBuf,
    /// Human-readable origin for diagnostics.
    pub kind: DaemonLocationKind,
}

/// Where a [`DaemonLocation`] came from. Used purely for logging.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonLocationKind {
    /// The path `state::default_daemon_root()` resolves to. Respects any
    /// explicit `HARNESS_DAEMON_DATA_HOME` / `HARNESS_APP_GROUP_ID` the user
    /// set before the CLI launched.
    NaturalDefault,
    /// The Harness Monitor app group container, used by the sandboxed
    /// managed daemon and by `harness daemon dev`.
    AppGroupContainer {
        /// Group identifier baked into the path.
        app_group_id: &'static str,
    },
    /// The XDG/`HARNESS_DATA_HOME` fallback root
    /// (`~/.local/share/harness/daemon`).
    XdgDataHome,
}

/// Result of [`adopt_running_daemon_root`]. Emitted at `tracing::info!`
/// level by bridge subcommands so "where did my bridge land?" is greppable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdoptionOutcome {
    /// `state::daemon_root()` already points at a live daemon - nothing
    /// changed.
    AlreadyCoherent { root: PathBuf },
    /// The effective root had no live daemon, but another candidate did.
    /// The process-local override was flipped to that candidate.
    Adopted { from: PathBuf, to: PathBuf },
    /// No candidate had a live daemon. Caller should proceed with
    /// `default_root` and optionally warn.
    NoRunningDaemon { default_root: PathBuf },
}

/// Build the ordered list of plausible daemon roots for the current host.
///
/// The order is:
/// 1. Whatever `state::default_daemon_root()` resolves to right now
///    (respects explicit env).
/// 2. On macOS only: the Harness Monitor app group container
///    (`~/Library/Group Containers/<HARNESS_MONITOR_APP_GROUP_ID>/harness/daemon`),
///    skipped if it coincides with #1.
/// 3. `harness_data_root().join("daemon")` (the XDG/`HARNESS_DATA_HOME`
///    fallback), skipped if it coincides with #1 or #2.
///
/// The list is deduplicated, so if the user's env already points at the
/// group container or the XDG path they appear exactly once.
#[must_use]
pub fn candidate_daemon_locations() -> Vec<DaemonLocation> {
    let mut candidates: Vec<DaemonLocation> = Vec::with_capacity(3);

    candidates.push(DaemonLocation {
        root: state::default_daemon_root(),
        kind: DaemonLocationKind::NaturalDefault,
    });

    if cfg!(target_os = "macos") {
        let group_root = host_home_dir()
            .join("Library")
            .join("Group Containers")
            .join(HARNESS_MONITOR_APP_GROUP_ID)
            .join("harness")
            .join("daemon");
        if !candidates
            .iter()
            .any(|candidate| candidate.root == group_root)
        {
            candidates.push(DaemonLocation {
                root: group_root,
                kind: DaemonLocationKind::AppGroupContainer {
                    app_group_id: HARNESS_MONITOR_APP_GROUP_ID,
                },
            });
        }
    }

    let xdg_root = harness_data_root().join("daemon");
    if !candidates
        .iter()
        .any(|candidate| candidate.root == xdg_root)
    {
        candidates.push(DaemonLocation {
            root: xdg_root,
            kind: DaemonLocationKind::XdgDataHome,
        });
    }

    candidates
}

/// Return the first candidate whose daemon singleton lock is currently held
/// by a live process. Returns `None` if no daemon is running anywhere we can
/// see.
///
/// Uses [`state::daemon_lock_is_held_at`] so it is immune to PID reuse and
/// stale manifests - a missing or releasable flock means "dead or never
/// started", no matter what a leftover manifest file says.
///
/// Candidate probes run sequentially. Each probe is a cheap `open` plus a
/// non-blocking `try_lock_exclusive` - usually sub-millisecond even on a
/// cold cache. Parallelizing would only trade complexity for noise, so we
/// stay serial.
#[must_use]
pub fn running_daemon_location() -> Option<DaemonLocation> {
    for candidate in candidate_daemon_locations() {
        let lock_path = candidate.root.join(state::DAEMON_LOCK_FILE);
        if state::daemon_lock_is_held_at(&lock_path) {
            return Some(candidate);
        }
    }
    None
}

/// Ensure this process's `state::daemon_root()` resolves to a path with a
/// live daemon, installing a process-local override if needed.
///
/// Idempotent - safe to call at the top of every bridge subcommand. Logic:
///
/// 1. If the currently effective `state::daemon_root()` is alive, return
///    [`AdoptionOutcome::AlreadyCoherent`] unchanged.
/// 2. Otherwise, scan [`candidate_daemon_locations`] for a live candidate.
///    On the first hit, install an override via
///    [`state::set_daemon_root_override`] and return
///    [`AdoptionOutcome::Adopted`].
/// 3. If nothing is alive anywhere, leave the override untouched and return
///    [`AdoptionOutcome::NoRunningDaemon`] so the caller can warn.
///
/// Adoption never overrides a live user-specified root, so the escape
/// hatch (`HARNESS_DAEMON_DATA_HOME`, `HARNESS_APP_GROUP_ID`) keeps
/// working: if that explicit target is actually running a daemon, it wins.
/// Adoption only steps in when the default target is empty.
#[must_use]
pub fn adopt_running_daemon_root() -> AdoptionOutcome {
    let effective_root = state::daemon_root();
    let effective_lock = effective_root.join(state::DAEMON_LOCK_FILE);
    if state::daemon_lock_is_held_at(&effective_lock) {
        return AdoptionOutcome::AlreadyCoherent {
            root: effective_root,
        };
    }

    for candidate in candidate_daemon_locations() {
        if candidate.root == effective_root {
            continue;
        }
        let lock = candidate.root.join(state::DAEMON_LOCK_FILE);
        if state::daemon_lock_is_held_at(&lock) {
            state::set_daemon_root_override(Some(candidate.root.clone()));
            return AdoptionOutcome::Adopted {
                from: effective_root,
                to: candidate.root,
            };
        }
    }

    AdoptionOutcome::NoRunningDaemon {
        default_root: effective_root,
    }
}

#[cfg(test)]
mod tests;
