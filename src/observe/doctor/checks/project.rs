use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::workspace::{harness_data_root, project_context_dir};

use super::{DoctorCheck, error_check, ok_check, skipped_check};

pub(super) fn auto_detect_kuma_repo_root(start: &Path) -> Option<PathBuf> {
    start.ancestors().find_map(|ancestor| {
        let go_mod = ancestor.join("go.mod");
        let text = fs::read_to_string(&go_mod).ok()?;
        if text.contains("github.com/kumahq/kuma") {
            Some(ancestor.to_path_buf())
        } else {
            None
        }
    })
}

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

pub(super) fn check_project_plugin_root(project_dir: &Path) -> DoctorCheck {
    let plugin_root = project_dir.join(".claude").join("plugins").join("suite");
    if plugin_root.is_dir() {
        ok_check(
            "observe_project_plugin",
            "project",
            "Project suite plugin root is present.",
            Some(&plugin_root),
        )
    } else {
        error_check(
            "observe_project_plugin_missing",
            "project",
            "Project suite plugin root is missing.",
            Some(&plugin_root),
            false,
            Some(
                "Run the project bootstrap so `.claude/plugins/suite` exists in the active project.",
            ),
        )
    }
}

pub(super) fn check_project_plugin_wrapper(project_dir: &Path) -> DoctorCheck {
    let wrapper = project_dir
        .join(".claude")
        .join("plugins")
        .join("suite")
        .join("harness");
    if wrapper.exists() {
        ok_check(
            "observe_project_wrapper",
            "project",
            "Project harness wrapper is present.",
            Some(&wrapper),
        )
    } else {
        error_check(
            "observe_project_wrapper_missing",
            "project",
            "Project harness wrapper is missing.",
            Some(&wrapper),
            false,
            Some(
                "Reinstall the suite plugin so `.claude/plugins/suite/harness` resolves the current harness CLI.",
            ),
        )
    }
}

pub(super) fn check_repo_provider_contract(repo_root: Option<&Path>) -> Vec<DoctorCheck> {
    let Some(repo_root) = repo_root else {
        return vec![
            skipped_check(
                "observe_repo_make_contract",
                "repo",
                "Kuma provider-contract check skipped because no Kuma repo root was detected.",
                None,
                Some(
                    "Run observe doctor from a Kuma checkout to verify k3d and remote provider contracts.",
                ),
            ),
            skipped_check(
                "observe_repo_remote_publish_contract",
                "repo",
                "Remote publish-contract check skipped because no Kuma repo root was detected.",
                None,
                Some(
                    "Run observe doctor from a Kuma checkout to verify remote image publish targets.",
                ),
            ),
        ];
    };

    vec![
        if repo_has_current_make_contract(repo_root) {
            ok_check(
                "observe_repo_make_contract",
                "repo",
                "Kuma repo exposes the current cluster make contract.",
                Some(repo_root),
            )
        } else {
            error_check(
                "observe_repo_make_contract",
                "repo",
                "Kuma repo is missing the current cluster make contract required by harness.",
                Some(repo_root),
                false,
                Some("Expected mk/k3d.mk + mk/k8s.mk with CLUSTER and k3d/cluster/* targets."),
            )
        },
        if repo_has_remote_publish_contract(repo_root) {
            ok_check(
                "observe_repo_remote_publish_contract",
                "repo",
                "Kuma repo exposes the remote image publish contract required by harness.",
                Some(repo_root),
            )
        } else {
            error_check(
                "observe_repo_remote_publish_contract",
                "repo",
                "Kuma repo is missing the remote image publish contract required by harness.",
                Some(repo_root),
                false,
                Some(
                    "Expected mk/docker.mk targets for images/release, docker/push, and manifests/json/release.",
                ),
            )
        },
    ]
}

pub(super) fn check_lifecycle_contract(project_dir: &Path) -> Vec<DoctorCheck> {
    let hooks_path = project_dir
        .join(".claude")
        .join("plugins")
        .join("suite")
        .join("hooks")
        .join("hooks.json");
    vec![check_lifecycle_file(
        &hooks_path,
        "observe_lifecycle_hooks",
        "project",
    )]
}

fn repo_has_current_make_contract(repo_root: &Path) -> bool {
    let k3d = repo_root.join("mk").join("k3d.mk");
    let k8s = repo_root.join("mk").join("k8s.mk");
    file_contains_all(
        &k3d,
        &[
            "k3d/cluster/start:",
            "k3d/cluster/deploy/helm:",
            "k3d/cluster/stop:",
        ],
    ) && file_contains_all(&k8s, &["CLUSTER"])
}

fn repo_has_remote_publish_contract(repo_root: &Path) -> bool {
    let docker = repo_root.join("mk").join("docker.mk");
    file_contains_all(
        &docker,
        &["images/release:", "docker/push:", "manifests/json/release:"],
    )
}

fn file_contains_all(path: &Path, needles: &[&str]) -> bool {
    let Ok(text) = fs::read_to_string(path) else {
        return false;
    };
    needles.iter().all(|needle| text.contains(needle))
}

fn check_lifecycle_file(path: &Path, code: &'static str, kind: &'static str) -> DoctorCheck {
    let expected = [
        "harness pre-compact --project-dir",
        "harness agents session-start --agent claude --project-dir",
        "harness agents session-stop --agent claude --project-dir",
    ];
    let legacy = legacy_lifecycle_needles();

    if !path.exists() {
        return error_check(
            code,
            kind,
            "Lifecycle configuration file is missing.",
            Some(path),
            false,
            None,
        );
    }

    match fs::read_to_string(path) {
        Ok(text) => {
            if legacy.iter().any(|needle| text.contains(needle)) {
                return error_check(
                    code,
                    kind,
                    "Lifecycle configuration still uses removed grouped setup commands.",
                    Some(path),
                    true,
                    Some(
                        "Replace grouped `harness setup ...` lifecycle commands with `harness agents ...` or other current top-level lifecycle commands.",
                    ),
                );
            }
            let missing: Vec<&str> = expected
                .into_iter()
                .filter(|needle| !text.contains(needle))
                .collect();
            if !missing.is_empty() {
                return error_check(
                    code,
                    kind,
                    format!(
                        "Lifecycle configuration is missing expected commands: {}.",
                        missing.join(", ")
                    ),
                    Some(path),
                    true,
                    None,
                );
            }
            ok_check(
                code,
                kind,
                "Lifecycle configuration matches the current CLI contract.",
                Some(path),
            )
        }
        Err(error) => error_check(
            code,
            kind,
            format!("Lifecycle configuration cannot be read: {error}"),
            Some(path),
            false,
            None,
        ),
    }
}

fn legacy_lifecycle_needles() -> [String; 3] {
    [
        ["harness", " setup", " pre-compact"].concat(),
        ["harness", " setup", " session-start"].concat(),
        ["harness", " setup", " session-stop"].concat(),
    ]
}
