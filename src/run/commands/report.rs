use clap::{Args, Subcommand};

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::run::GroupVerdict;
use crate::run::application::{GroupReportRequest, ReportCheckOutcome, check_report_compactness};
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_application;

impl Execute for ReportArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        report(&self.cmd)
    }
}

#[non_exhaustive]
/// Report validation and group finalization.
#[derive(Debug, Clone, Subcommand)]
pub enum ReportCommand {
    /// Validate report compactness.
    Check {
        /// Report path; defaults to the tracked run report.
        #[arg(long)]
        report: Option<String>,
    },
    /// Finalize a completed group.
    Group {
        /// Completed group ID (e.g. g02).
        #[arg(long)]
        group_id: String,
        /// Recorded group verdict.
        #[arg(long, value_parser = ["pass", "fail", "skip"])]
        status: String,
        /// Evidence file path; repeat to record multiple artifacts.
        #[arg(long)]
        evidence: Vec<String>,
        /// Recorded evidence label to resolve to the latest matching artifact.
        #[arg(long)]
        evidence_label: Vec<String>,
        /// Optional state-capture label to snapshot pod state before finalizing.
        #[arg(long)]
        capture_label: Option<String>,
        /// Optional one-line note to include in the story result.
        #[arg(long)]
        note: Option<String>,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
}

/// Arguments for `harness report`.
#[derive(Debug, Clone, Args)]
pub struct ReportArgs {
    /// Report subcommand.
    #[command(subcommand)]
    pub cmd: ReportCommand,
}

/// Report validation and group finalization.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn report(cmd: &ReportCommand) -> Result<i32, CliError> {
    match cmd {
        ReportCommand::Check { report } => {
            match check_report_compactness(report.as_deref())? {
                ReportCheckOutcome::Missing => println!("no report generated yet"),
                ReportCheckOutcome::Valid => println!("report is compact enough"),
            }
            Ok(0)
        }
        ReportCommand::Group {
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label,
            note,
            run_dir,
        } => report_group(
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label.as_deref(),
            note.as_deref(),
            run_dir,
        ),
    }
}

fn report_group(
    group_id: &str,
    status: &str,
    evidence: &[String],
    evidence_label: &[String],
    capture_label: Option<&str>,
    note: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let mut run = resolve_run_application(run_dir_args)?;
    let verdict: GroupVerdict = status.parse().map_err(|()| {
        CliErrorKind::usage_error(format!(
            "unknown group status '{status}': must be pass, fail, or skip"
        ))
    })?;

    run.finalize_group_report(&GroupReportRequest {
        group_id,
        verdict,
        evidence,
        evidence_label,
        capture_label,
        note,
    })?;
    Ok(0)
}
