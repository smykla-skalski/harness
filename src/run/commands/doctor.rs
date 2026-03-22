use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::application::diagnostics::{RunDiagnosticCheck, RunDiagnosticReport};
use crate::run::application::{self};
use crate::run::args::RunDirArgs;

impl Execute for DoctorArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        doctor(&self.run_dir, self.json)
    }
}

/// Arguments for `harness run doctor`.
#[derive(Debug, Clone, Args)]
pub struct DoctorArgs {
    /// Output machine-readable JSON.
    #[arg(long)]
    pub json: bool,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Diagnose run state and pointer health.
///
/// # Errors
/// Returns `CliError` on operational failures.
pub fn doctor(run_dir_args: &RunDirArgs, json: bool) -> Result<i32, CliError> {
    let report = application::doctor(run_dir_args)?;
    render_report(&report, json);
    Ok(if report.ok { 0 } else { 2 })
}

pub(super) fn render_report(report: &RunDiagnosticReport, json: bool) {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(report).expect("typed run diagnostics JSON serializes")
        );
        return;
    }

    render_text_report(report);
}

fn render_text_report(report: &RunDiagnosticReport) {
    println!("{}", report.command);
    println!("run: {}", report.target.run_dir);
    println!("pointer: {}", report.target.current_run_pointer);

    if !report.repairs_applied.is_empty() {
        println!("repairs:");
        for repair in &report.repairs_applied {
            render_repair(repair);
        }
    }

    for check in &report.checks {
        render_check(check);
    }
}

fn render_repair(repair: &RunDiagnosticCheck) {
    println!("- [{}] {}", repair.code, repair.summary);
    if let Some(path) = &repair.path {
        println!("  path: {path}");
    }
}

fn render_check(check: &RunDiagnosticCheck) {
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
