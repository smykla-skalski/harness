use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;
use crate::observe::application::maintenance::{load_observer_state, render_json};
use crate::observe::scan;
use crate::observe::session;

#[derive(serde::Serialize)]
struct IssueVerification {
    issue_id: String,
    status: &'static str,
    evidence_lines: Vec<usize>,
}

#[derive(serde::Serialize)]
struct ResolveStartResult {
    resolved_line: usize,
    method: &'static str,
}

pub(in crate::observe::application) fn execute_verify(
    session_id: &str,
    issue_id: &str,
    since_line: Option<usize>,
    project_hint: Option<&str>,
    observe_id: &str,
    agent: Option<HookAgent>,
) -> Result<i32, CliError> {
    let path = session::find_session_for_agent(session_id, project_hint, agent)?;
    let project_context_root = super::storage::project_context_root_for_session_path(&path);
    let observer_state = load_observer_state(&project_context_root, observe_id, session_id)?;
    let open_issue = observer_state
        .open_issues
        .iter()
        .find(|issue| issue.issue_id == issue_id);

    let from_line =
        since_line.unwrap_or_else(|| open_issue.map_or(0, |issue| issue.first_seen_line));

    let (issues, _last_line) = scan::scan(&path, from_line)?;

    let still_reproducing = open_issue.is_some_and(|open_issue| {
        issues.iter().any(|issue| {
            issue.code == open_issue.code && issue.fingerprint == open_issue.fingerprint
        })
    });

    let status = if still_reproducing {
        "still_reproducing"
    } else {
        "potentially_resolved"
    };

    let evidence_lines: Vec<usize> = if let Some(open_issue) = open_issue {
        issues
            .iter()
            .filter(|issue| {
                issue.code == open_issue.code && issue.fingerprint == open_issue.fingerprint
            })
            .map(|issue| issue.line)
            .collect()
    } else {
        Vec::new()
    };

    println!(
        "{}",
        render_json(&IssueVerification {
            issue_id: issue_id.to_string(),
            status,
            evidence_lines,
        })
    );
    Ok(0)
}

pub(in crate::observe::application) fn execute_resolve_start(
    session_id: &str,
    value: &str,
    project_hint: Option<&str>,
    agent: Option<HookAgent>,
) -> Result<i32, CliError> {
    let path = session::find_session_for_agent(session_id, project_hint, agent)?;
    let resolved = scan::resolve_from(&path, value)?;

    let method = if value.parse::<usize>().is_ok() {
        "numeric"
    } else if value.len() >= 10
        && value[..4]
            .chars()
            .all(|character| character.is_ascii_digit())
        && value.contains('T')
    {
        "timestamp"
    } else {
        "prose"
    };

    println!(
        "{}",
        render_json(&ResolveStartResult {
            resolved_line: resolved,
            method,
        })
    );
    Ok(0)
}
