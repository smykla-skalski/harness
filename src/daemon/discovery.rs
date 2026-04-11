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
        if !candidates.iter().any(|candidate| candidate.root == group_root) {
            candidates.push(DaemonLocation {
                root: group_root,
                kind: DaemonLocationKind::AppGroupContainer {
                    app_group_id: HARNESS_MONITOR_APP_GROUP_ID,
                },
            });
        }
    }

    let xdg_root = harness_data_root().join("daemon");
    if !candidates.iter().any(|candidate| candidate.root == xdg_root) {
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
mod tests {
    use super::*;

    use std::fs;
    use std::path::Path;

    use fs2::FileExt;
    use tempfile::tempdir;

    /// Reset the daemon root override. Every test should call this in its
    /// teardown because tests run single-threaded and the override is
    /// process-global.
    fn reset_override() {
        state::set_daemon_root_override(None);
    }

    /// Build a fake "running daemon" at `root`: create the daemon directory,
    /// write an empty lock file, acquire an exclusive flock, and return the
    /// holding file so the caller can keep it alive for the lifetime of the
    /// test.
    fn fake_running_daemon(root: &Path) -> fs::File {
        fs::create_dir_all(root).expect("create fake daemon root");
        let lock_path = root.join(state::DAEMON_LOCK_FILE);
        let file = fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .expect("open fake lock");
        file.try_lock_exclusive()
            .expect("acquire fake daemon flock");
        file
    }

    #[test]
    fn candidate_daemon_locations_dedupes_when_env_points_at_xdg() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                (
                    "HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                (
                    "HARNESS_HOST_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                reset_override();
                let candidates = candidate_daemon_locations();
                let natural_count = candidates
                    .iter()
                    .filter(|candidate| {
                        matches!(candidate.kind, DaemonLocationKind::NaturalDefault)
                    })
                    .count();
                let xdg_count = candidates
                    .iter()
                    .filter(|candidate| matches!(candidate.kind, DaemonLocationKind::XdgDataHome))
                    .count();
                assert_eq!(natural_count, 1);
                assert_eq!(
                    xdg_count, 0,
                    "xdg candidate should dedupe with the natural default"
                );
                reset_override();
            },
        );
    }

    #[test]
    fn candidate_daemon_locations_on_macos_includes_group_container() {
        if !cfg!(target_os = "macos") {
            return;
        }
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                (
                    "HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                (
                    "HARNESS_HOST_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                reset_override();
                let candidates = candidate_daemon_locations();
                let has_group = candidates.iter().any(|candidate| {
                    matches!(
                        candidate.kind,
                        DaemonLocationKind::AppGroupContainer { app_group_id }
                            if app_group_id == HARNESS_MONITOR_APP_GROUP_ID
                    )
                });
                assert!(
                    has_group,
                    "macOS candidates must include the Monitor app group container"
                );
                reset_override();
            },
        );
    }

    #[test]
    fn running_daemon_location_returns_none_when_no_daemon_is_live() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                (
                    "HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                (
                    "HARNESS_HOST_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                reset_override();
                assert!(running_daemon_location().is_none());
                reset_override();
            },
        );
    }

    #[test]
    fn running_daemon_location_picks_group_container_when_only_it_is_live() {
        if !cfg!(target_os = "macos") {
            return;
        }
        let tmp = tempdir().expect("tempdir");
        let home = tmp.path();
        let group_root = home
            .join("Library")
            .join("Group Containers")
            .join(HARNESS_MONITOR_APP_GROUP_ID)
            .join("harness")
            .join("daemon");
        let _holder = fake_running_daemon(&group_root);
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                (
                    "XDG_DATA_HOME",
                    Some(home.to_str().expect("utf8 path")),
                ),
                ("HOME", Some(home.to_str().expect("utf8 path"))),
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 path"))),
            ],
            || {
                reset_override();
                let running = running_daemon_location().expect("group container alive");
                assert_eq!(running.root, group_root);
                reset_override();
            },
        );
    }

    #[test]
    fn adopt_is_noop_when_default_is_live() {
        let tmp = tempdir().expect("tempdir");
        let home = tmp.path();
        let xdg_daemon = home.join("harness").join("daemon");
        let _holder = fake_running_daemon(&xdg_daemon);
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", Some(home.to_str().expect("utf8 path"))),
                ("HOME", Some(home.to_str().expect("utf8 path"))),
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 path"))),
            ],
            || {
                reset_override();
                let outcome = adopt_running_daemon_root();
                assert!(
                    matches!(
                        &outcome,
                        AdoptionOutcome::AlreadyCoherent { root } if *root == xdg_daemon
                    ),
                    "expected AlreadyCoherent, got {outcome:?}"
                );
                // Override should not have been installed.
                assert_eq!(state::daemon_root(), xdg_daemon);
                reset_override();
            },
        );
    }

    #[test]
    #[expect(
        clippy::cognitive_complexity,
        reason = "one happy-path test covering adopt + assert + second-call idempotency"
    )]
    fn adopt_switches_override_when_default_is_empty_and_alt_is_live() {
        if !cfg!(target_os = "macos") {
            return;
        }
        let tmp = tempdir().expect("tempdir");
        let home = tmp.path();
        // Natural default (XDG) has nothing running.
        // The group container has a fake running daemon.
        let group_root = home
            .join("Library")
            .join("Group Containers")
            .join(HARNESS_MONITOR_APP_GROUP_ID)
            .join("harness")
            .join("daemon");
        let _holder = fake_running_daemon(&group_root);
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", Some(home.to_str().expect("utf8 path"))),
                ("HOME", Some(home.to_str().expect("utf8 path"))),
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 path"))),
            ],
            || {
                reset_override();
                let natural_before = state::default_daemon_root();
                let outcome = adopt_running_daemon_root();
                match &outcome {
                    AdoptionOutcome::Adopted { from, to } => {
                        assert_eq!(*from, natural_before);
                        assert_eq!(*to, group_root);
                    }
                    other => panic!("expected Adopted, got {other:?}"),
                }
                // Subsequent daemon_root() calls see the override.
                assert_eq!(state::daemon_root(), group_root);
                // A second adoption call is a no-op AlreadyCoherent.
                let second = adopt_running_daemon_root();
                assert!(
                    matches!(
                        &second,
                        AdoptionOutcome::AlreadyCoherent { root } if *root == group_root
                    ),
                    "second adopt should be AlreadyCoherent, got {second:?}"
                );
                reset_override();
            },
        );
    }

    #[test]
    fn adopt_returns_no_running_daemon_when_nothing_alive() {
        let tmp = tempdir().expect("tempdir");
        let home = tmp.path();
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", Some(home.to_str().expect("utf8 path"))),
                ("HOME", Some(home.to_str().expect("utf8 path"))),
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 path"))),
            ],
            || {
                reset_override();
                let outcome = adopt_running_daemon_root();
                assert!(
                    matches!(outcome, AdoptionOutcome::NoRunningDaemon { .. }),
                    "expected NoRunningDaemon, got {outcome:?}"
                );
                // daemon_root() should still resolve to the natural default.
                assert_eq!(state::daemon_root(), state::default_daemon_root());
                reset_override();
            },
        );
    }

    #[test]
    fn adopt_respects_explicit_env_when_that_root_is_live() {
        let tmp = tempdir().expect("tempdir");
        let home = tmp.path();
        let explicit_root = home.join("explicit").join("harness").join("daemon");
        let _holder = fake_running_daemon(&explicit_root);
        let explicit_data_home = home.join("explicit");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(explicit_data_home.to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", Some(home.to_str().expect("utf8 path"))),
                ("HOME", Some(home.to_str().expect("utf8 path"))),
                ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 path"))),
            ],
            || {
                reset_override();
                let outcome = adopt_running_daemon_root();
                assert!(
                    matches!(
                        &outcome,
                        AdoptionOutcome::AlreadyCoherent { root } if *root == explicit_root
                    ),
                    "explicit env must win when live, got {outcome:?}"
                );
                reset_override();
            },
        );
    }
}
