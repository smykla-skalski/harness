use std::fs;

use super::*;

#[test]
fn data_root_prefers_xdg_data_home() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg_data = tmp.path().join("xdg-data");
    temp_env::with_var("XDG_DATA_HOME", Some(&xdg_data), || {
        assert_eq!(data_root(), xdg_data);
    });
}

#[test]
fn data_root_ignores_monitor_app_group_when_xdg_data_home_is_absent() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().unwrap())),
            ("HARNESS_HOST_HOME", Some(tmp.path().to_str().unwrap())),
            ("XDG_DATA_HOME", None),
            ("HARNESS_APP_GROUP_ID", Some("Q498EB36N4.io.harnessmonitor")),
        ],
        || {
            assert_ne!(
                data_root(),
                tmp.path()
                    .join("Library")
                    .join("Group Containers")
                    .join("Q498EB36N4.io.harnessmonitor")
            );
        },
    );
}

#[test]
fn explicit_project_context_path_uses_project_scope() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg_data = tmp.path().join("xdg-data");
    let project_dir = tmp.path().join("project");
    fs::create_dir_all(&project_dir).unwrap();

    temp_env::with_var("XDG_DATA_HOME", Some(&xdg_data), || {
        let context_dir = session_context_dir_for_project(&project_dir);
        assert_eq!(
            context_dir.parent(),
            Some(xdg_data.join("harness").join("contexts").as_path())
        );
        let pointer = current_run_context_path_for_project(&project_dir);
        assert_eq!(pointer, context_dir.join("current-run.json"));
    });
}

#[test]
fn project_context_dir_is_idempotent() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg_data = tmp.path().join("xdg-data");
    let project_dir = tmp.path().join("myproject");
    fs::create_dir_all(&project_dir).unwrap();

    temp_env::with_var("XDG_DATA_HOME", Some(&xdg_data), || {
        let first = project_context_dir(&project_dir);
        // Create the context root on disk so canonicalize works.
        fs::create_dir_all(&first).unwrap();
        let second = project_context_dir(&first);
        assert_eq!(
            first, second,
            "passing context_root back in should return the same path"
        );
    });
}

#[test]
fn project_context_dir_recognizes_subdirectory() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg_data = tmp.path().join("xdg-data");
    let project_dir = tmp.path().join("myproject");
    fs::create_dir_all(&project_dir).unwrap();

    temp_env::with_var("XDG_DATA_HOME", Some(&xdg_data), || {
        let context_root = project_context_dir(&project_dir);
        let sub = context_root.join("orchestration").join("sessions");
        fs::create_dir_all(&sub).unwrap();
        let result = project_context_dir(&sub);
        assert_eq!(
            result, context_root,
            "subdirectory should resolve to the context root"
        );
    });
}

#[test]
fn project_context_dir_rejects_non_hex_project_name() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg_data = tmp.path().join("xdg-data");
    let fake_project = xdg_data
        .join("harness")
        .join("projects")
        .join("project-not-hex-at-all!");
    fs::create_dir_all(&fake_project).unwrap();

    temp_env::with_var("XDG_DATA_HOME", Some(&xdg_data), || {
        let result = project_context_dir(&fake_project);
        // Should NOT be idempotent - the name doesn't match project-{16hex}.
        assert_ne!(result, fake_project);
    });
}

#[test]
fn is_project_context_dir_name_validates_format() {
    assert!(is_project_context_dir_name("project-9fe5ce4237976a0a"));
    assert!(is_project_context_dir_name("project-b72ed763e074d381"));
    assert!(!is_project_context_dir_name("project-short"));
    assert!(!is_project_context_dir_name("project-ZZZZZZZZZZZZZZZZ"));
    assert!(!is_project_context_dir_name("notaproject-9fe5ce4237976a0a"));
    assert!(!is_project_context_dir_name("project-9fe5ce4237976a0a0")); // 17 chars
}

#[test]
#[cfg(target_os = "macos")]
fn data_root_prefers_app_group_container_when_present() {
    temp_env::with_vars(
        vec![
            ("XDG_DATA_HOME", None::<&str>),
            ("HARNESS_APP_GROUP_ID", Some("Q498EB36N4.io.harnessmonitor")),
        ],
        || {
            let home = dirs_home();
            let group = home
                .join("Library")
                .join("Group Containers")
                .join("Q498EB36N4.io.harnessmonitor");
            let expected = if group.exists() {
                group
            } else {
                home.join("Library").join("Application Support")
            };
            assert_eq!(super::data_root(), expected);
        },
    );
}
