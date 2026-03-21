use crate::errors::CliError;
use crate::observe::application::ObserveFilter;
use crate::observe::application::maintenance::{load_observer_state, save_observer_state};
use crate::observe::output;
use crate::observe::scan;
use crate::observe::session;
use crate::observe::types::{self, IssueSeverity};

pub(in crate::observe::application) fn execute_cycle(
    session_id: &str,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut observer_state = load_observer_state(session_id)?;
    let from_line = observer_state.cursor;

    let path = session::find_session(session_id, project_hint)?;
    let (issues, last_line) = scan::scan(&path, from_line)?;

    let now = chrono::Utc::now().to_rfc3339();
    observer_state.cursor = last_line;
    observer_state.last_scan_time.clone_from(&now);

    for issue in &issues {
        let existing = observer_state.open_issues.iter_mut().find(|open_issue| {
            open_issue.code == issue.code && open_issue.fingerprint == issue.fingerprint
        });
        if let Some(open_issue) = existing {
            open_issue.occurrence_count += 1;
            open_issue.last_seen_line = issue.line;
        } else {
            observer_state.open_issues.push(types::OpenIssue {
                issue_id: issue.id.clone(),
                code: issue.code,
                fingerprint: issue.fingerprint.clone(),
                first_seen_line: issue.line,
                last_seen_line: issue.line,
                occurrence_count: 1,
                severity: issue.severity,
                category: issue.category,
                summary: issue.summary.clone(),
                fix_safety: issue.fix_safety,
            });
        }
    }

    observer_state.cycle_history.push(types::CycleRecord {
        timestamp: now,
        from_line,
        to_line: last_line,
        new_issues: issues.len(),
        resolved: 0,
    });

    if issues.is_empty() && observer_state.baseline_issue_ids.is_empty() {
        observer_state.baseline_issue_ids = observer_state
            .open_issues
            .iter()
            .map(|open_issue| open_issue.issue_id.clone())
            .collect();
    }

    save_observer_state(session_id, &observer_state)?;

    if issues.is_empty() {
        return Ok(0);
    }

    let critical_count = issues
        .iter()
        .filter(|issue| issue.severity == IssueSeverity::Critical)
        .count();
    let display_end = if last_line > 0 { last_line - 1 } else { 0 };
    println!(
        "Cycle: lines {from_line}-{display_end}, {} new issues ({critical_count} critical)",
        issues.len()
    );
    for issue in &issues {
        println!("{}", output::render_json(issue));
    }
    println!("{}", output::render_summary(&issues, last_line));

    Ok(0)
}

pub(in crate::observe::application) fn execute_resume(
    session_id: &str,
    filter: &ObserveFilter,
) -> Result<i32, CliError> {
    let state = load_observer_state(session_id)?;
    let mut resumed_filter = filter.clone();
    resumed_filter.from_line = state.cursor;
    scan::execute_scan(session_id, &resumed_filter)
}
