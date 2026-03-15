use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

use crate::cli::{ReportCommand, RunDirArgs};
use crate::context::{RunContext, RunLookup};
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};
use crate::resolve::resolve_run_directory;
use crate::rules::suite_runner::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::schema::RunReport;

/// Report validation and group finalization.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(cmd: &ReportCommand) -> Result<i32, CliError> {
    match cmd {
        ReportCommand::Check { report } => run_check(report.as_deref()),
        ReportCommand::Group {
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label,
            note,
            run_dir,
        } => run_group(
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

fn run_check(report_path: Option<&str>) -> Result<i32, CliError> {
    let path = report_path
        .map(PathBuf::from)
        .ok_or_else(|| -> CliError { CliErrorKind::missing_run_context_value("report").into() })?;

    let report = RunReport::from_markdown(&path)?;
    let body = report.to_markdown();
    let line_count = body.lines().count();
    let code_blocks = body.matches("```").count() / 2;

    if line_count > REPORT_LINE_LIMIT {
        return Err(CliErrorKind::report_line_limit(
            line_count.to_string(),
            REPORT_LINE_LIMIT.to_string(),
        )
        .into());
    }
    if code_blocks > REPORT_CODE_BLOCK_LIMIT {
        return Err(CliErrorKind::report_code_block_limit(
            code_blocks.to_string(),
            REPORT_CODE_BLOCK_LIMIT.to_string(),
        )
        .into());
    }

    println!("report is compact enough");
    Ok(0)
}

fn run_group(
    group_id: &str,
    status: &str,
    evidence: &[String],
    evidence_label: &[String],
    capture_label: Option<&str>,
    note: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let lookup = RunLookup {
        run_dir: run_dir_args.run_dir.clone(),
        run_id: run_dir_args.run_id.clone(),
        run_root: run_dir_args.run_root.clone(),
    };

    let run_dir = resolve_run_directory(&lookup)?.run_dir;

    if evidence.is_empty() && evidence_label.is_empty() && capture_label.is_none() {
        return Err(CliErrorKind::ReportGroupEvidenceRequired.into());
    }

    let ctx = RunContext::from_run_dir(&run_dir)?;

    let Some(mut run_status) = ctx.status else {
        return Err(CliErrorKind::MissingRunStatus.into());
    };

    if run_status
        .executed_group_ids()
        .iter()
        .any(|id| id == group_id)
    {
        return Err(CliErrorKind::run_group_already_recorded(group_id.to_string()).into());
    }

    let now = utc_now();
    let group_entry = serde_json::json!({
        "group_id": group_id,
        "verdict": status,
        "completed_at": now,
    });
    run_status.executed_groups.push(group_entry);
    run_status.last_completed_group = Some(group_id.to_string());
    run_status.last_updated_utc = Some(now.clone());

    match status {
        "pass" => run_status.counts.passed += 1,
        "fail" => run_status.counts.failed += 1,
        "skip" => run_status.counts.skipped += 1,
        _ => {}
    }

    if let Some(n) = note {
        run_status.notes.push(n.to_string());
    }

    let status_json =
        serde_json::to_string_pretty(&run_status).expect("serialization of valid JSON");
    fs::write(ctx.layout.status_path(), format!("{status_json}\n"))?;

    let mut report = RunReport::from_markdown(&ctx.layout.report_path())?;

    let mut section = format!("\n## Group: {group_id}\n\n**Verdict:** {status}\n");
    let all_refs: Vec<&str> = evidence
        .iter()
        .map(String::as_str)
        .chain(evidence_label.iter().map(String::as_str))
        .chain(capture_label)
        .collect();
    if !all_refs.is_empty() {
        let _ = write!(section, "\n**Evidence:** {}\n", all_refs.join(", "));
    }
    if let Some(n) = note {
        let _ = write!(section, "\n**Note:** {n}\n");
    }

    report.body.push_str(&section);
    report.save()?;

    Ok(0)
}
