use std::fmt::Write as _;
use std::path::PathBuf;

use crate::audit_log::write_run_status_with_audit;
use crate::cli::{ReportCommand, RunDirArgs};
use crate::commands::resolve_run_dir;
use crate::context::RunContext;
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};
use crate::rules::suite_runner::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::schema::{RunCounts, RunReport};
use crate::workflow::runner::ensure_execution_phase;

/// Report validation and group finalization.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn report(cmd: &ReportCommand) -> Result<i32, CliError> {
    match cmd {
        ReportCommand::Check { report } => report_check(report.as_deref()),
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

fn report_check(report_path: Option<&str>) -> Result<i32, CliError> {
    let path = if let Some(p) = report_path {
        PathBuf::from(p)
    } else {
        let context = RunContext::from_current()?.ok_or_else(|| -> CliError {
            CliErrorKind::missing_run_context_value("report").into()
        })?;
        context.layout.report_path()
    };

    if !path.exists() {
        println!("no report generated yet");
        return Ok(0);
    }

    let rpt = RunReport::from_markdown(&path)?;
    let body = rpt.to_markdown();
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

fn report_group(
    group_id: &str,
    status: &str,
    evidence: &[String],
    evidence_label: &[String],
    capture_label: Option<&str>,
    note: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;

    if evidence.is_empty() && evidence_label.is_empty() && capture_label.is_none() {
        return Err(CliErrorKind::ReportGroupEvidenceRequired.into());
    }

    let ctx = RunContext::from_run_dir(&run_dir)?;

    let Some(mut run_status) = ctx.status else {
        return Err(CliErrorKind::MissingRunStatus.into());
    };

    // Validate status before doing any mutation.
    match status {
        "pass" | "fail" | "skip" => {}
        _ => {
            return Err(CliErrorKind::usage_error(format!(
                "unknown group status '{status}': must be pass, fail, or skip"
            ))
            .into());
        }
    }

    let existing_verdict = find_group_verdict(&run_status.executed_groups, group_id);

    if let Some(previous) = &existing_verdict {
        if previous == status {
            // Same status reported again - silently succeed for idempotency.
            return Ok(0);
        }
        // Different status - update the entry and adjust counts.
        eprintln!("group {group_id} status updated from {previous} to {status}");
        decrement_count(&mut run_status.counts, previous);
        update_group_verdict(&mut run_status.executed_groups, group_id, status);
    } else {
        let now = utc_now();
        let group_entry = serde_json::json!({
            "group_id": group_id,
            "verdict": status,
            "completed_at": now,
        });
        run_status.executed_groups.push(group_entry);
    }

    let now = utc_now();
    run_status.last_completed_group = Some(group_id.to_string());
    run_status.last_updated_utc = Some(now.clone());

    match status {
        "pass" => run_status.counts.passed += 1,
        "fail" => run_status.counts.failed += 1,
        "skip" => run_status.counts.skipped += 1,
        _ => unreachable!(),
    }

    if let Some(n) = note {
        run_status.notes.push(n.to_string());
    }

    // Write report section first so status is never updated if report fails.
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

    write_run_status_with_audit(
        &ctx.layout.run_dir(),
        &run_status,
        None,
        Some("execution"),
        Some(group_id),
    )?;

    // Auto-advance runner state from bootstrap/preflight to execution when
    // a group result is recorded.
    ensure_execution_phase(&run_dir)?;

    Ok(0)
}

/// Find the verdict string for a group that was already recorded.
/// Returns `None` if the group is not in the list.
fn find_group_verdict(executed_groups: &[serde_json::Value], group_id: &str) -> Option<String> {
    for entry in executed_groups {
        match entry {
            serde_json::Value::String(s) if s == group_id => {
                // Legacy string-only entries have no verdict field.
                return Some(String::new());
            }
            serde_json::Value::Object(object) => {
                if object.get("group_id").and_then(|v| v.as_str()) == Some(group_id) {
                    return object
                        .get("verdict")
                        .and_then(|v| v.as_str())
                        .map(str::to_string);
                }
            }
            _ => {}
        }
    }
    None
}

/// Overwrite the verdict field on an existing executed-group entry.
fn update_group_verdict(executed_groups: &mut [serde_json::Value], group_id: &str, verdict: &str) {
    for entry in executed_groups.iter_mut() {
        if let serde_json::Value::Object(object) = entry
            && object.get("group_id").and_then(|v| v.as_str()) == Some(group_id)
        {
            object.insert(
                "verdict".to_string(),
                serde_json::Value::String(verdict.to_string()),
            );
            return;
        }
    }
}

/// Decrement the count for a given status string. Saturates at zero.
fn decrement_count(counts: &mut RunCounts, status: &str) {
    match status {
        "pass" => counts.passed = counts.passed.saturating_sub(1),
        "fail" => counts.failed = counts.failed.saturating_sub(1),
        "skip" => counts.skipped = counts.skipped.saturating_sub(1),
        _ => {}
    }
}
