use std::collections::HashSet;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::observe::types::{Issue, IssueCode, IssueSeverity, OpenIssue};
use crate::observe::{is_observer_conflict, load_observer_state, save_observer_state};
use crate::session::service::{self, TaskSpec};
use crate::session::types::{SessionState, TaskSeverity, TaskSource};
use crate::workspace::{project_context_dir, utc_now};

pub(super) fn emit_watch_issues(issues: &[Issue], json: bool) {
    for issue in issues {
        if json {
            let line = serde_json::to_string(issue).unwrap_or_default();
            println!("{line}");
        } else {
            println!(
                "[{:?}] {} - {} (line {})",
                issue.severity, issue.code, issue.summary, issue.line,
            );
        }
    }
}

fn map_issue_severity(severity: IssueSeverity) -> TaskSeverity {
    match severity {
        IssueSeverity::Critical => TaskSeverity::Critical,
        IssueSeverity::Medium => TaskSeverity::Medium,
        IssueSeverity::Low => TaskSeverity::Low,
    }
}

/// Issue-aware task severity bridge shared by file-backed observe
/// (`session::observe`) and daemon observe (`daemon::service::
/// observe_persistence`). High-impact non-critical issue codes surface
/// as [`TaskSeverity::High`] or [`TaskSeverity::Critical`] regardless
/// of the classifier's own [`IssueSeverity`] tier.
#[must_use]
pub fn task_severity_for_issue(issue: &Issue) -> TaskSeverity {
    match issue.code {
        IssueCode::PythonTracebackOutput
        | IssueCode::PythonUsedInBashToolUse
        | IssueCode::HookDeniedToolCall
        | IssueCode::CrossAgentFileConflict => TaskSeverity::High,
        IssueCode::UnauthorizedGitCommitDuringRun | IssueCode::UnverifiedRecursiveRemove => {
            TaskSeverity::Critical
        }
        _ => map_issue_severity(issue.severity),
    }
}

pub(super) fn emit_results(issues: &[Issue], json: bool) -> Result<i32, CliError> {
    if json {
        let json_output = serde_json::to_string_pretty(issues)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        println!("{json_output}");
    } else {
        for issue in issues {
            println!(
                "[{:?}] {} - {} (line {})",
                issue.severity, issue.code, issue.summary, issue.line,
            );
        }
    }
    Ok(i32::from(!issues.is_empty()))
}

pub(super) fn create_work_items_for_issues(
    issues: &[Issue],
    session_id: &str,
    state: &SessionState,
    project_dir: &Path,
    actor_id: Option<&str>,
) -> Result<(), CliError> {
    let Some(actor_id) = actor_id.filter(|value| !value.trim().is_empty()) else {
        return Ok(());
    };
    let mut known_issue_ids: HashSet<String> = state
        .tasks
        .values()
        .filter_map(|task| task.observe_issue_id.clone())
        .collect();

    for issue in issues {
        if !known_issue_ids.insert(issue.id.clone()) {
            continue;
        }
        let title = format!("[{}] {}", issue.code, issue.summary);
        let spec = TaskSpec {
            title: &title,
            context: Some(&issue.details),
            severity: task_severity_for_issue(issue),
            suggested_fix: issue.fix_hint.as_deref(),
            source: TaskSource::Observe,
            observe_issue_id: Some(&issue.id),
        };
        let _ = service::create_task_with_source(session_id, &spec, actor_id, project_dir)?;
    }
    Ok(())
}

pub(crate) fn persist_observer_snapshot(
    state: &SessionState,
    project_dir: &Path,
    issues: &[Issue],
) -> Result<(), CliError> {
    let Some(observe_id) = state.observe_id.as_deref() else {
        return Err(CliError::from(CliErrorKind::session_parse_error(format!(
            "session '{}' is missing observe_id for observe snapshot persistence",
            state.session_id
        ))));
    };
    let project_context_root = project_context_dir(project_dir);

    for _attempt in 0..3 {
        let mut observer_state =
            load_observer_state(&project_context_root, observe_id, &state.session_id)?;
        let now = utc_now();
        let to_line = issues
            .iter()
            .map(|issue| issue.line.saturating_add(1))
            .max()
            .unwrap_or(observer_state.cursor);

        observer_state.cursor = to_line;
        observer_state.last_scan_time.clone_from(&now);
        if observer_state.project_hint.is_none() && !state.project_name.is_empty() {
            observer_state.project_hint = Some(state.project_name.clone());
        }

        for issue in issues {
            if let Some(open_issue) = observer_state.open_issues.iter_mut().find(|open_issue| {
                open_issue.code == issue.code && open_issue.fingerprint == issue.fingerprint
            }) {
                update_open_issue(open_issue, issue);
                continue;
            }

            observer_state
                .open_issues
                .push(open_issue_from_issue(issue));
        }

        if issues.is_empty() && observer_state.baseline_issue_ids.is_empty() {
            observer_state.baseline_issue_ids = observer_state
                .open_issues
                .iter()
                .map(|open_issue| open_issue.issue_id.clone())
                .collect();
        }

        match save_observer_state(&project_context_root, observe_id, &observer_state) {
            Ok(_) => return Ok(()),
            Err(error) if is_observer_conflict(&error) => {}
            Err(error) => return Err(error),
        }
    }

    Err(CliError::from(CliErrorKind::session_parse_error(
        "observer state changed repeatedly during observe persistence; retry the action",
    )))
}

fn open_issue_from_issue(issue: &Issue) -> OpenIssue {
    OpenIssue {
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
    }
}

fn update_open_issue(open_issue: &mut OpenIssue, issue: &Issue) {
    open_issue.occurrence_count = open_issue.occurrence_count.saturating_add(1);
    open_issue.last_seen_line = issue.line;
    open_issue.severity = issue.severity;
    open_issue.category = issue.category;
    open_issue.summary.clone_from(&issue.summary);
    open_issue.fix_safety = issue.fix_safety;
    open_issue
        .evidence_excerpt
        .clone_from(&issue.evidence_excerpt);
}
