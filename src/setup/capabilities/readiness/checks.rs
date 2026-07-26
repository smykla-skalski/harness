use std::path::Path;

use fs_err as fs;

use crate::setup::capabilities::model::{ReadinessCheck, ReadinessCheckScope, ReadinessStatus};
use crate::setup::wrapper::choose_install_dir_with_home;
use crate::workspace::harness_data_root;

use super::CapabilityProbe;

pub(super) fn build_checks(project_dir: &Path, probe: &dyn CapabilityProbe) -> Vec<ReadinessCheck> {
    let path_env = probe.path_env();
    let home_dir = probe.home_dir();
    let data_root = harness_data_root();

    vec![
        check_data_root_writable(&data_root),
        check_project_dir_exists(project_dir),
        check_wrapper_install_target(&path_env, &home_dir),
    ]
}

fn check_data_root_writable(path: &Path) -> ReadinessCheck {
    let probe_path = path.join(".capabilities-write-check");
    let result = fs::create_dir_all(path)
        .and_then(|()| {
            fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(&probe_path)
        })
        .map(|_| ());
    let _ = fs::remove_file(&probe_path);

    match result {
        Ok(()) => pass(
            "data_root_writable",
            ReadinessCheckScope::Machine,
            "Harness data root is writable.",
            Some(path),
            None,
        ),
        Err(error) => fail(
            "data_root_writable",
            ReadinessCheckScope::Machine,
            format!("Harness data root is not writable: {error}"),
            Some(path),
            Some("Set XDG_DATA_HOME to a writable location before using harness."),
        ),
    }
}

fn check_project_dir_exists(project_dir: &Path) -> ReadinessCheck {
    if project_dir.is_dir() {
        pass(
            "project_dir_exists",
            ReadinessCheckScope::Project,
            "Project directory exists.",
            Some(project_dir),
            None,
        )
    } else {
        fail(
            "project_dir_exists",
            ReadinessCheckScope::Project,
            "Project directory is missing.",
            Some(project_dir),
            Some("Run the command from a project checkout or pass `--project-dir`."),
        )
    }
}

fn check_wrapper_install_target(path_env: &str, home_dir: &Path) -> ReadinessCheck {
    match choose_install_dir_with_home(path_env, home_dir) {
        Ok((target, _)) => pass(
            "wrapper_install_target_available",
            ReadinessCheckScope::Project,
            "Harness wrapper install target is available.",
            Some(&target),
            None,
        ),
        Err(error) => fail(
            "wrapper_install_target_available",
            ReadinessCheckScope::Project,
            format!("Harness wrapper install target is unavailable: {error}"),
            None,
            Some("Add a writable user bin directory such as `~/.local/bin` to PATH."),
        ),
    }
}

pub(super) fn pass(
    code: &str,
    scope: ReadinessCheckScope,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<&str>,
) -> ReadinessCheck {
    check(
        code,
        scope,
        ReadinessStatus::Pass,
        summary,
        path,
        hint.map(str::to_string),
    )
}

pub(super) fn fail(
    code: &str,
    scope: ReadinessCheckScope,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<&str>,
) -> ReadinessCheck {
    check(
        code,
        scope,
        ReadinessStatus::Fail,
        summary,
        path,
        hint.map(str::to_string),
    )
}

fn check(
    code: &str,
    scope: ReadinessCheckScope,
    status: ReadinessStatus,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<String>,
) -> ReadinessCheck {
    ReadinessCheck {
        code: code.to_string(),
        scope,
        status,
        summary: summary.into(),
        path: path.map(|item| item.display().to_string()),
        hint,
    }
}
