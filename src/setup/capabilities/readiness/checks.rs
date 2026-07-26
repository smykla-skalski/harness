use std::env::split_paths;
use std::path::Path;

use fs_err as fs;

use crate::setup::capabilities::model::{ReadinessCheck, ReadinessCheckScope, ReadinessStatus};
use crate::setup::wrapper::choose_install_dir_with_home;
use crate::workspace::harness_data_root;

use super::CapabilityProbe;
use super::repo::{
    check_repo_is_kuma_checkout, check_repo_make_contract, check_repo_remote_publish_contract,
    check_repo_root_exists, check_repo_root_resolved, is_kuma_checkout,
};

pub(super) fn build_checks(
    project_dir: &Path,
    repo_root: Option<&Path>,
    probe: &dyn CapabilityProbe,
) -> Vec<ReadinessCheck> {
    let path_env = probe.path_env();
    let home_dir = probe.home_dir();
    let data_root = harness_data_root();
    let repo_exists = repo_root.is_some_and(Path::is_dir);
    let repo_is_kuma = repo_root
        .filter(|path| path.is_dir())
        .is_some_and(is_kuma_checkout);

    vec![
        check_data_root_writable(&data_root),
        check_project_dir_exists(project_dir),
        check_wrapper_install_target(&path_env, &home_dir),
        check_binary_present(
            "make_binary_present",
            "`make` is available.",
            "`make` is missing.",
            "Install `make` and ensure it is on PATH.",
            "make",
            probe,
        ),
        check_repo_root_resolved(repo_root),
        check_repo_root_exists(repo_root),
        check_repo_is_kuma_checkout(repo_root, repo_exists),
        check_repo_make_contract(repo_root, repo_is_kuma),
        check_repo_remote_publish_contract(repo_root, repo_is_kuma),
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

fn check_binary_present(
    code: &str,
    success: &str,
    failure: &str,
    hint: &str,
    command: &str,
    probe: &dyn CapabilityProbe,
) -> ReadinessCheck {
    if probe.command_on_path(command) {
        pass(code, ReadinessCheckScope::Machine, success, None, None)
    } else {
        fail(
            code,
            ReadinessCheckScope::Machine,
            failure,
            None,
            Some(hint),
        )
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

pub(super) fn skipped(
    code: &str,
    scope: ReadinessCheckScope,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<&str>,
) -> ReadinessCheck {
    check(
        code,
        scope,
        ReadinessStatus::Skipped,
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

pub(super) fn command_on_path(command: &str, path_env: &str) -> bool {
    let candidate = Path::new(command);
    if candidate.components().count() > 1 {
        return candidate.is_file();
    }

    split_paths(path_env)
        .map(|dir| dir.join(command))
        .any(|path| path.is_file())
}
