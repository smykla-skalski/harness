use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::workspace::{harness_data_root, project_context_dir};

use super::{DoctorCheck, error_check, ok_check};

pub(super) fn check_global_install(project_dir: &Path) -> Vec<DoctorCheck> {
    let mut checks = vec![];
    let Some(home) = env::var_os("HOME").map(PathBuf::from) else {
        checks.push(error_check(
            "observe_home_missing",
            "install",
            "HOME is not set, so harness cannot verify Claude and binary install paths.",
            None,
            false,
            None,
        ));
        return checks;
    };

    let claude_projects = home.join(".claude").join("projects");
    if claude_projects.is_dir() {
        checks.push(ok_check(
            "observe_claude_projects",
            "install",
            "Claude projects directory is present.",
            Some(&claude_projects),
        ));
    } else {
        checks.push(error_check(
            "observe_claude_projects_missing",
            "install",
            "Claude projects directory is missing.",
            Some(&claude_projects),
            false,
            Some("Create ~/.claude/projects or run Claude Code once to bootstrap it."),
        ));
    }

    let harness_path = home.join(".local").join("bin").join("harness");
    if harness_path.exists() {
        checks.push(ok_check(
            "observe_harness_binary",
            "install",
            "Installed harness binary is present.",
            Some(&harness_path),
        ));
    } else {
        checks.push(error_check(
            "observe_harness_binary_missing",
            "install",
            "Installed harness binary is missing.",
            Some(&harness_path),
            false,
            Some("Run `mise run install` to install the release binary."),
        ));
    }

    let data_root = harness_data_root();
    if data_root.is_dir() {
        checks.push(ok_check(
            "observe_data_root",
            "workspace",
            "Harness data directory exists.",
            Some(&data_root),
        ));
    } else {
        checks.push(ok_check(
            "observe_data_root_pending",
            "workspace",
            "Harness data directory does not exist yet. It will be created on first use.",
            Some(&data_root),
        ));
    }

    let observe_dir = project_context_dir(project_dir)
        .join("agents")
        .join("observe");
    match fs::create_dir_all(&observe_dir) {
        Ok(()) => checks.push(ok_check(
            "observe_state_dir",
            "workspace",
            "Observe state directory is writable.",
            Some(&observe_dir),
        )),
        Err(error) => checks.push(error_check(
            "observe_state_dir_unwritable",
            "workspace",
            format!("Observe state directory cannot be created: {error}"),
            Some(&observe_dir),
            false,
            None,
        )),
    }

    checks
}
