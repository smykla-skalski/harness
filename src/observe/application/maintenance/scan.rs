use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::observe::application::ObserveFilter;
use crate::observe::application::maintenance::{load_observer_state, save_observer_state};
use crate::observe::output;
use crate::observe::scan;
use crate::observe::session;
use crate::observe::types::{self, IssueSeverity};

pub(in crate::observe::application) fn execute_cycle(
    session_id: &str,
    project_hint: Option<&str>,
    observe_id: &str,
    agent: Option<HookAgent>,
) -> Result<i32, CliError> {
    let path = session::find_session_for_agent(session_id, project_hint, agent)?;
    let project_context_root = super::storage::project_context_root_for_session_path(&path);

    for _attempt in 0..3 {
        let mut observer_state =
            load_observer_state(&project_context_root, observe_id, session_id)?;
        let from_line = observer_state.cursor;
        let (issues, last_line) = scan::scan(&path, from_line)?;

        let now = chrono::Utc::now().to_rfc3339();
        observer_state.cursor = last_line;
        observer_state.last_scan_time.clone_from(&now);
        observer_state.last_sweep_at = Some(now.clone());

        for issue in &issues {
            let existing = observer_state.open_issues.iter_mut().find(|open_issue| {
                open_issue.code == issue.code && open_issue.fingerprint == issue.fingerprint
            });
            if let Some(open_issue) = existing {
                open_issue.occurrence_count += 1;
                open_issue.last_seen_line = issue.line;
                open_issue
                    .evidence_excerpt
                    .clone_from(&issue.evidence_excerpt);
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
                    evidence_excerpt: issue.evidence_excerpt.clone(),
                });
            }
        }

        if issues.is_empty() && observer_state.baseline_issue_ids.is_empty() {
            observer_state.baseline_issue_ids = observer_state
                .open_issues
                .iter()
                .map(|open_issue| open_issue.issue_id.clone())
                .collect();
        }

        match save_observer_state(&project_context_root, observe_id, &observer_state) {
            Ok(_) => {
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
                return Ok(0);
            }
            Err(error) if super::storage::is_observer_conflict(&error) => {}
            Err(error) => return Err(error),
        }
    }

    Err(CliError::from(CliErrorKind::session_parse_error(
        "observer state changed repeatedly during cycle; retry the command",
    )))
}

pub(in crate::observe::application) fn execute_resume(
    session_id: &str,
    filter: &ObserveFilter,
) -> Result<i32, CliError> {
    let path =
        session::find_session_for_agent(session_id, filter.project_hint.as_deref(), filter.agent)?;
    let project_context_root = super::storage::project_context_root_for_session_path(&path);
    let state = load_observer_state(
        &project_context_root,
        filter.observe_id.as_str(),
        session_id,
    )?;
    let mut resumed_filter = filter.clone();
    resumed_filter.from_line = state.cursor;
    scan::execute_scan(session_id, &resumed_filter)
}
