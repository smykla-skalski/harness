use std::path::Path;

use super::DoctorCheck;

mod project;
mod runtime;

pub(super) fn check_global_install(project_dir: &Path) -> Vec<DoctorCheck> {
    project::check_global_install(project_dir)
}

pub(super) fn check_compact_handoff(project_dir: &Path, compact_path: &Path) -> DoctorCheck {
    runtime::check_compact_handoff(project_dir, compact_path)
}

pub(super) fn check_runtime_bootstrap_contract(project_dir: &Path) -> Vec<DoctorCheck> {
    runtime::check_runtime_bootstrap_contract(project_dir)
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

fn skipped_check(
    code: &'static str,
    kind: &'static str,
    summary: impl Into<String>,
    path: Option<&Path>,
    hint: Option<&str>,
) -> DoctorCheck {
    DoctorCheck {
        code,
        kind,
        status: "skipped",
        summary: summary.into(),
        path: path.map(|value| value.display().to_string()),
        repairable: false,
        hint: hint.map(str::to_string),
    }
}
