use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::errors::CliError;
use crate::infra::io::read_json_typed;
use crate::run::context::CurrentRunPointer;
use crate::workspace::compact::{
    compact_latest_path, handoff_version, load_latest_compact_handoff,
};
use crate::workspace::{current_run_context_path_for_project, harness_data_root};

#[derive(Debug, Clone, Serialize)]
struct DoctorTarget {
    project_dir: String,
    current_run_pointer: String,
    compact_handoff: String,
}

#[derive(Debug, Clone, Serialize)]
struct DoctorCheck {
    code: &'static str,
    kind: &'static str,
    status: &'static str,
    summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    repairable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<String>,
}

#[derive(Debug, Serialize)]
struct DoctorReport {
    ok: bool,
    command: &'static str,
    target: DoctorTarget,
    checks: Vec<DoctorCheck>,
    repairs_applied: Vec<DoctorCheck>,
    remaining_findings: Vec<DoctorCheck>,
}

/// Validate observer setup, project wiring, and ambient harness state.
pub(super) fn execute_doctor(json: bool, project_dir: Option<&str>) -> Result<i32, CliError> {
    let project_dir = resolve_project_dir(project_dir)?;
    let report = build_report(&project_dir);
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&report).expect("typed observe doctor JSON serializes")
        );
    } else {
        render_human(&report);
    }
    Ok(if report.ok { 0 } else { 2 })
}

fn resolve_project_dir(raw: Option<&str>) -> Result<PathBuf, CliError> {
    let candidate = if let Some(path) = raw {
        PathBuf::from(path)
    } else if let Ok(project_dir) = env::var("CLAUDE_PROJECT_DIR") {
        let trimmed = project_dir.trim();
        if trimmed.is_empty() {
            env::current_dir()?
        } else {
            PathBuf::from(trimmed)
        }
    } else {
        env::current_dir()?
    };

    Ok(candidate.canonicalize().unwrap_or(candidate))
}

fn build_report(project_dir: &Path) -> DoctorReport {
    let pointer_path = current_run_context_path_for_project(project_dir);
    let compact_path = compact_latest_path(project_dir);

    let mut checks = vec![];
    checks.extend(check_global_install());
    checks.push(check_project_plugin_root(project_dir));
    checks.push(check_project_plugin_wrapper(project_dir));
    checks.extend(check_lifecycle_contract(project_dir));
    checks.push(check_current_run_pointer(&pointer_path));
    checks.push(check_compact_handoff(project_dir, &compact_path));

    let remaining_findings: Vec<DoctorCheck> = checks
        .iter()
        .filter(|check| check.status != "ok")
        .cloned()
        .collect();

    DoctorReport {
        ok: remaining_findings.is_empty(),
        command: "observe doctor",
        target: DoctorTarget {
            project_dir: project_dir.display().to_string(),
            current_run_pointer: pointer_path.display().to_string(),
            compact_handoff: compact_path.display().to_string(),
        },
        checks,
        repairs_applied: vec![],
        remaining_findings,
    }
}

fn render_human(report: &DoctorReport) {
    println!("observe doctor");
    println!("project: {}", report.target.project_dir);
    println!("pointer: {}", report.target.current_run_pointer);
    println!("compact: {}", report.target.compact_handoff);
    for check in &report.checks {
        println!(
            "{} [{}] {}",
            check.status.to_uppercase(),
            check.code,
            check.summary
        );
        if let Some(path) = &check.path {
            println!("path: {path}");
        }
        if let Some(hint) = &check.hint {
            println!("hint: {hint}");
        }
    }
}

fn check_global_install() -> Vec<DoctorCheck> {
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

    let observe_dir = data_root.join("observe");
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

fn check_project_plugin_root(project_dir: &Path) -> DoctorCheck {
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

fn check_project_plugin_wrapper(project_dir: &Path) -> DoctorCheck {
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
                "Reinstall the suite plugin so `.claude/plugins/suite/harness` points at the current binary.",
            ),
        )
    }
}

fn check_lifecycle_contract(project_dir: &Path) -> Vec<DoctorCheck> {
    let mut checks = vec![];
    let hooks_path = project_dir
        .join(".claude")
        .join("plugins")
        .join("suite")
        .join("hooks")
        .join("hooks.json");
    checks.push(check_lifecycle_file(
        &hooks_path,
        "observe_lifecycle_hooks",
        "project",
    ));

    let settings_path = project_dir.join(".claude").join("settings.json");
    if settings_path.exists() {
        checks.push(check_lifecycle_file(
            &settings_path,
            "observe_lifecycle_settings",
            "project",
        ));
    } else {
        checks.push(ok_check(
            "observe_lifecycle_settings_absent",
            "project",
            "Project settings.json is absent. No local lifecycle drift was detected there.",
            Some(&settings_path),
        ));
    }

    checks
}

fn check_lifecycle_file(path: &Path, code: &'static str, kind: &'static str) -> DoctorCheck {
    let expected = [
        "harness pre-compact --project-dir",
        "harness session-start --project-dir",
        "harness session-stop --project-dir",
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
                        "Replace grouped `harness setup ...` lifecycle commands with top-level commands.",
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

fn check_current_run_pointer(pointer_path: &Path) -> DoctorCheck {
    if !pointer_path.exists() {
        return ok_check(
            "observe_current_run_pointer_absent",
            "pointer",
            "No current run pointer is recorded for this project.",
            Some(pointer_path),
        );
    }

    match read_json_typed::<CurrentRunPointer>(pointer_path) {
        Ok(pointer) => {
            let run_dir = pointer.layout.run_dir();
            if run_dir.is_dir() {
                ok_check(
                    "observe_current_run_pointer",
                    "pointer",
                    format!(
                        "Current run pointer is readable and targets {}.",
                        run_dir.display()
                    ),
                    Some(pointer_path),
                )
            } else {
                error_check(
                    "observe_current_run_pointer_stale",
                    "pointer",
                    format!(
                        "Current run pointer targets a missing run directory: {}.",
                        run_dir.display()
                    ),
                    Some(pointer_path),
                    true,
                    Some("Use `harness run repair` or remove the stale pointer."),
                )
            }
        }
        Err(error) => error_check(
            "observe_current_run_pointer_invalid",
            "pointer",
            format!("Current run pointer is unreadable: {error}"),
            Some(pointer_path),
            true,
            Some("Use `harness run repair` or remove the corrupt pointer."),
        ),
    }
}

fn check_compact_handoff(project_dir: &Path, compact_path: &Path) -> DoctorCheck {
    if !compact_path.exists() {
        return ok_check(
            "observe_compact_handoff_absent",
            "compact",
            "No compact handoff is currently recorded for this project.",
            Some(compact_path),
        );
    }

    match load_latest_compact_handoff(project_dir) {
        Ok(Some(handoff)) => {
            if handoff.version != handoff_version() {
                return error_check(
                    "observe_compact_handoff_version",
                    "compact",
                    format!(
                        "Compact handoff uses version {}, expected {}.",
                        handoff.version,
                        handoff_version()
                    ),
                    Some(compact_path),
                    false,
                    Some("Re-run compaction so harness writes a fresh handoff."),
                );
            }
            ok_check(
                "observe_compact_handoff",
                "compact",
                format!(
                    "Compact handoff is readable with status {}.",
                    handoff.status
                ),
                Some(compact_path),
            )
        }
        Ok(None) => ok_check(
            "observe_compact_handoff_absent",
            "compact",
            "No compact handoff is currently recorded for this project.",
            Some(compact_path),
        ),
        Err(error) => error_check(
            "observe_compact_handoff_invalid",
            "compact",
            format!("Compact handoff is unreadable: {error}"),
            Some(compact_path),
            false,
            Some("Delete the stale handoff or regenerate it with a fresh compaction cycle."),
        ),
    }
}

fn ok_check(
    code: &'static str,
    kind: &'static str,
    summary: impl Into<String>,
    path: Option<&Path>,
) -> DoctorCheck {
    DoctorCheck {
        code,
        kind,
        status: "ok",
        summary: summary.into(),
        path: path.map(|value| value.display().to_string()),
        repairable: false,
        hint: None,
    }
}

fn error_check(
    code: &'static str,
    kind: &'static str,
    summary: impl Into<String>,
    path: Option<&Path>,
    repairable: bool,
    hint: Option<&str>,
) -> DoctorCheck {
    DoctorCheck {
        code,
        kind,
        status: "error",
        summary: summary.into(),
        path: path.map(|value| value.display().to_string()),
        repairable,
        hint: hint.map(str::to_string),
    }
}
