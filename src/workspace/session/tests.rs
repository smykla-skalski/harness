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
