use std::env;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;
use crate::workspace::compact::compact_latest_path;
use crate::workspace::current_run_context_path_for_project;

mod checks;

#[derive(Debug, Clone, Serialize)]
struct DoctorTarget {
    project_dir: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    repo_root: Option<String>,
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
pub(super) fn execute_doctor(
    json: bool,
    project_dir: Option<&str>,
    _agent: Option<HookAgent>,
) -> Result<i32, CliError> {
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
    let repo_root = checks::auto_detect_kuma_repo_root(project_dir);
    let pointer_path = current_run_context_path_for_project(project_dir);
    let compact_path = compact_latest_path(project_dir);

    let mut checks = vec![];
    checks.extend(checks::check_global_install(project_dir));
    checks.push(checks::check_project_plugin_root(project_dir));
    checks.push(checks::check_project_plugin_wrapper(project_dir));
    checks.extend(checks::check_lifecycle_contract(project_dir));
    checks.extend(checks::check_runtime_bootstrap_contract(project_dir));
    checks.extend(checks::check_repo_provider_contract(repo_root.as_deref()));
    checks.push(checks::check_current_run_pointer(&pointer_path));
    checks.push(checks::check_compact_handoff(project_dir, &compact_path));

    let remaining_findings: Vec<DoctorCheck> = checks
        .iter()
        .filter(|check| check.status == "error")
        .cloned()
        .collect();

    DoctorReport {
        ok: remaining_findings.is_empty(),
        command: "observe doctor",
        target: DoctorTarget {
            project_dir: project_dir.display().to_string(),
            repo_root: repo_root.as_ref().map(|path| path.display().to_string()),
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
    if let Some(repo_root) = &report.target.repo_root {
        println!("repo: {repo_root}");
    }
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
