use std::env;
use std::path::{Path, PathBuf};

use serde::Serialize;

use harness_kernel::errors::CliError;
use crate::hooks::adapters::HookAgent;
use crate::workspace::compact::compact_latest_path;

mod checks;

#[derive(Debug, Clone, Serialize)]
struct DoctorTarget {
    project_dir: String,
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
    let compact_path = compact_latest_path(project_dir);

    let mut checks = vec![];
    checks.extend(checks::check_global_install(project_dir));
    checks.extend(checks::check_runtime_bootstrap_contract(project_dir));
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

#[cfg(test)]
mod tests {
    use fs_err as fs;
    use temp_env::with_vars;

    use crate::hooks::adapters::HookAgent;
    use crate::setup::wrapper::planned_agent_bootstrap_files;

    use super::{DoctorReport, build_report};

    fn prepare_home(tmp: &std::path::Path) -> std::path::PathBuf {
        let home = tmp.join("home");
        fs::create_dir_all(home.join(".claude").join("projects")).unwrap();
        fs::create_dir_all(home.join(".local").join("bin")).unwrap();
        fs::write(home.join(".local").join("bin").join("harness"), "").unwrap();
        home
    }

    fn report_for(tmp: &std::path::Path, project_dir: &std::path::Path) -> DoctorReport {
        let home = prepare_home(tmp);
        with_vars(
            [
                ("HOME", Some(home.to_str().unwrap())),
                ("XDG_DATA_HOME", Some(tmp.to_str().unwrap())),
            ],
            || build_report(project_dir),
        )
    }

    #[test]
    fn build_report_omits_suite_plugin_checks() {
        let tmp = tempfile::tempdir().unwrap();
        let report = report_for(tmp.path(), tmp.path());

        assert!(!report.checks.iter().any(|check| matches!(
            check.code,
            "observe_project_plugin"
                | "observe_project_plugin_missing"
                | "observe_project_wrapper"
                | "observe_project_wrapper_missing"
        )));
    }

    /// A project carrying exactly what bootstrap writes has to satisfy the
    /// doctor. Without this, a check can outlive the thing it inspects and every
    /// run reports a finding nobody can act on: the lifecycle check kept looking
    /// for a plugin file that bootstrap stopped writing, so the command exited
    /// non-zero in every project it was ever run in.
    #[test]
    fn a_bootstrapped_project_has_no_findings() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp.path().join("project");
        fs::create_dir_all(&project_dir).unwrap();

        for agent in [
            HookAgent::Claude,
            HookAgent::Codex,
            HookAgent::Gemini,
            HookAgent::Copilot,
            HookAgent::Vibe,
            HookAgent::OpenCode,
        ] {
            for (path, contents) in planned_agent_bootstrap_files(&project_dir, agent, &[]) {
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(&path, contents).unwrap();
            }
        }

        let report = report_for(tmp.path(), &project_dir);
        let findings: Vec<&str> = report
            .remaining_findings
            .iter()
            .map(|check| check.code)
            .collect();

        assert!(
            report.ok,
            "a project bootstrapped from the current contract still reports: {findings:?}"
        );
    }
}
