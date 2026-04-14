use tempfile::tempdir;

use crate::workspace::harness_data_root;

use super::super::{daemon_root, default_daemon_root, set_daemon_root_override};
use super::reset_override_for_tests;

#[test]
fn daemon_root_prefers_explicit_daemon_data_home() {
    let tmp = tempdir().expect("tempdir");
    let daemon_data_home = tmp.path().join("daemon-data-home");
    let xdg_data_home = tmp.path().join("xdg-data-home");

    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(daemon_data_home.to_str().expect("utf8 path")),
            ),
            (
                "XDG_DATA_HOME",
                Some(xdg_data_home.to_str().expect("utf8 path")),
            ),
        ],
        || {
            assert_eq!(
                daemon_root(),
                daemon_data_home.join("harness").join("daemon")
            );
        },
    );
}

#[test]
fn daemon_root_uses_app_group_without_relocating_session_data() {
    let tmp = tempdir().expect("tempdir");

    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
            (
                "HARNESS_HOST_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("XDG_DATA_HOME", None),
            ("HARNESS_DAEMON_DATA_HOME", None),
            ("HARNESS_APP_GROUP_ID", Some("Q498EB36N4.io.harnessmonitor")),
        ],
        || {
            assert_eq!(
                daemon_root(),
                tmp.path()
                    .join("Library")
                    .join("Group Containers")
                    .join("Q498EB36N4.io.harnessmonitor")
                    .join("harness")
                    .join("daemon")
            );
            assert_ne!(
                harness_data_root(),
                tmp.path()
                    .join("Library")
                    .join("Group Containers")
                    .join("Q498EB36N4.io.harnessmonitor")
                    .join("harness")
            );
        },
    );
}

#[test]
fn daemon_root_override_takes_precedence_over_env() {
    let tmp = tempdir().expect("tempdir");
    let override_root = tmp.path().join("forced");
    temp_env::with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
            ("HARNESS_APP_GROUP_ID", None),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
        ],
        || {
            reset_override_for_tests();
            set_daemon_root_override(Some(override_root.clone()));
            assert_eq!(daemon_root(), override_root);
            assert_ne!(default_daemon_root(), override_root);
            reset_override_for_tests();
        },
    );
}

#[test]
fn daemon_root_override_clears_when_set_to_none() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
            ("HARNESS_APP_GROUP_ID", None),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
        ],
        || {
            reset_override_for_tests();
            set_daemon_root_override(Some(tmp.path().join("ignored")));
            set_daemon_root_override(None);
            assert_eq!(daemon_root(), default_daemon_root());
            reset_override_for_tests();
        },
    );
}
