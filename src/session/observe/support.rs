use std::collections::HashSet;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::observe::types::{Issue, IssueSeverity};
use crate::session::service::{self, TaskSpec};
use crate::session::types::{SessionState, TaskSeverity, TaskSource};

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

pub(super) fn map_severity(severity: IssueSeverity) -> TaskSeverity {
    match severity {
        IssueSeverity::Critical => TaskSeverity::Critical,
        IssueSeverity::Medium => TaskSeverity::Medium,
        IssueSeverity::Low => TaskSeverity::Low,
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
            severity: map_severity(issue.severity),
            suggested_fix: issue.fix_hint.as_deref(),
            source: TaskSource::Observe,
            observe_issue_id: Some(&issue.id),
        };
        let _ = service::create_task_with_source(session_id, &spec, actor_id, project_dir)?;
    }
    Ok(())
}
