use std::fs;
use std::path::Path;

use fs2::FileExt;
use tempfile::tempdir;

use super::*;

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
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
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
                .filter(|candidate| matches!(candidate.kind, DaemonLocationKind::NaturalDefault))
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
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
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
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
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
fn running_daemon_location_picks_xdg_when_only_xdg_is_live() {
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
            let running = running_daemon_location().expect("xdg daemon alive");
            assert_eq!(running.root, xdg_daemon);
            assert!(matches!(running.kind, DaemonLocationKind::NaturalDefault));
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
            ("XDG_DATA_HOME", Some(home.to_str().expect("utf8 path"))),
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
            assert_eq!(state::daemon_root(), group_root);
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
