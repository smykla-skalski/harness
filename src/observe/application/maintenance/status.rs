use std::collections::BTreeMap;

use serde::Serialize;

use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;
use crate::observe::application::maintenance::{load_observer_state, render_pretty_json};

#[derive(Serialize)]
struct ActiveWorkerView<'a> {
    issue_id: &'a str,
    target_file: &'a str,
    started_at: &'a str,
}

#[derive(Serialize)]
struct ObserverStatus<'a> {
    session_id: &'a str,
    cursor: usize,
    last_scan_time: &'a str,
    open_issues: usize,
    open_issues_by_severity: BTreeMap<String, usize>,
    resolved_issues: usize,
    muted_codes: Vec<String>,
    has_baseline: bool,
    handoff_safe: bool,
    active_workers: Vec<ActiveWorkerView<'a>>,
}

pub(in crate::observe::application) fn execute_status(
    session_id: &str,
    project_hint: Option<&str>,
    observe_id: &str,
    agent: Option<HookAgent>,
) -> Result<i32, CliError> {
    let project_context_root =
        super::storage::resolve_project_context_root(session_id, project_hint, agent)?;
    let state = load_observer_state(&project_context_root, observe_id, session_id)?;

    let by_severity: BTreeMap<String, usize> = {
        let mut map = BTreeMap::new();
        for issue in &state.open_issues {
            *map.entry(issue.severity.to_string()).or_default() += 1;
        }
        map
    };

    let status = ObserverStatus {
        session_id: &state.session_id,
        cursor: state.cursor,
        last_scan_time: &state.last_scan_time,
        open_issues: state.open_issues.len(),
        open_issues_by_severity: by_severity,
        resolved_issues: state.resolved_issue_ids.len(),
        muted_codes: state.muted_codes.iter().map(ToString::to_string).collect(),
        has_baseline: state.has_baseline(),
        handoff_safe: state.handoff_safe(),
        active_workers: state
            .active_workers
            .iter()
            .map(|worker| ActiveWorkerView {
                issue_id: &worker.issue_id,
                target_file: &worker.target_file,
                started_at: &worker.started_at,
            })
            .collect(),
    };
    println!("{}", render_pretty_json(&status));
    Ok(0)
}
