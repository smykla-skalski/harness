use std::collections::HashSet;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::observe::types::{Issue, IssueSeverity};
use crate::session::types::{TaskSeverity, TaskSource};

use super::{
    CliError, ObserveSessionRequest, ResolvedSession, SessionLogEntry, build_log_entry,
    session_service, utc_now,
};

struct ObserveTaskSpec {
    title: String,
    context: Option<String>,
    severity: TaskSeverity,
    suggested_fix: Option<String>,
    observe_issue_id: Option<String>,
}

pub(crate) fn observe_actor_id(request: Option<&ObserveSessionRequest>) -> Option<&str> {
    request
        .and_then(|request| request.actor.as_deref())
        .filter(|value| !value.trim().is_empty())
}

pub(crate) fn apply_issue_tasks_to_db(
    db: &DaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    let created_logs = apply_task_specs(
        resolved,
        actor_id,
        &issues.iter().map(issue_task_spec).collect::<Vec<_>>(),
    )?;
    persist_created_tasks_to_db(db, resolved, &created_logs)
}

pub(crate) async fn apply_issue_tasks_to_async_db(
    async_db: &AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    let created_logs = apply_task_specs(
        resolved,
        actor_id,
        &issues.iter().map(issue_task_spec).collect::<Vec<_>>(),
    )?;
    persist_created_tasks_to_async_db(async_db, resolved, &created_logs).await
}

pub(crate) async fn apply_heuristic_gap_tasks_to_async_db(
    async_db: &AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    let created_logs = apply_task_specs(
        resolved,
        actor_id,
        &issues
            .iter()
            .map(heuristic_gap_task_spec)
            .collect::<Vec<_>>(),
    )?;
    persist_created_tasks_to_async_db(async_db, resolved, &created_logs).await
}

fn apply_task_specs(
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    task_specs: &[ObserveTaskSpec],
) -> Result<Vec<SessionLogEntry>, CliError> {
    let Some(actor_id) = actor_id.filter(|value| !value.trim().is_empty()) else {
        return Ok(Vec::new());
    };
    let mut known_titles: HashSet<String> = resolved
        .state
        .tasks
        .values()
        .map(|task| task.title.clone())
        .collect();
    let now = utc_now();
    let mut created_logs = Vec::new();

    for task_spec in task_specs {
        if !known_titles.insert(task_spec.title.clone()) {
            continue;
        }
        let spec = session_service::TaskSpec {
            title: &task_spec.title,
            context: task_spec.context.as_deref(),
            severity: task_spec.severity,
            suggested_fix: task_spec.suggested_fix.as_deref(),
            source: TaskSource::Observe,
            observe_issue_id: task_spec.observe_issue_id.as_deref(),
        };
        let item = session_service::apply_create_task(&mut resolved.state, &spec, actor_id, &now)?;
        created_logs.push(build_log_entry(
            &resolved.state.session_id,
            session_service::log_task_created(&spec, &item),
            Some(actor_id),
            None,
        ));
    }

    Ok(created_logs)
}

fn persist_created_tasks_to_db(
    db: &DaemonDb,
    resolved: &ResolvedSession,
    created_logs: &[SessionLogEntry],
) -> Result<usize, CliError> {
    if created_logs.is_empty() {
        return Ok(0);
    }

    db.save_session_state(&resolved.project.project_id, &resolved.state)?;
    for entry in created_logs {
        db.append_log_entry(entry)?;
    }
    bump_session_in_db(db, &resolved.state.session_id)?;
    Ok(created_logs.len())
}

async fn persist_created_tasks_to_async_db(
    async_db: &AsyncDaemonDb,
    resolved: &ResolvedSession,
    created_logs: &[SessionLogEntry],
) -> Result<usize, CliError> {
    if created_logs.is_empty() {
        return Ok(0);
    }

    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    for entry in created_logs {
        async_db.append_log_entry(entry).await?;
    }
    bump_session_in_async_db(async_db, &resolved.state.session_id).await?;
    Ok(created_logs.len())
}

fn bump_session_in_db(db: &DaemonDb, session_id: &str) -> Result<(), CliError> {
    db.bump_change(session_id)?;
    db.bump_change("global")
}

async fn bump_session_in_async_db(
    async_db: &AsyncDaemonDb,
    session_id: &str,
) -> Result<(), CliError> {
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await
}

fn issue_task_spec(issue: &Issue) -> ObserveTaskSpec {
    ObserveTaskSpec {
        title: format!("[{}] {}", issue.code, issue.summary),
        context: Some(issue.details.clone()),
        severity: map_issue_severity(issue.severity),
        suggested_fix: issue.fix_hint.clone(),
        observe_issue_id: Some(issue.id.clone()),
    }
}

fn heuristic_gap_task_spec(issue: &Issue) -> ObserveTaskSpec {
    ObserveTaskSpec {
        title: format!(
            "[heuristic_gap] Real-time missed {} at line {}",
            issue.code, issue.line,
        ),
        context: Some(format!(
            "The periodic sweep caught issue '{}' (code: {}) at line {} that the real-time \
             watcher did not detect. Investigate why the real-time classification path missed \
             this pattern and add a rule or check.",
            issue.summary, issue.code, issue.line,
        )),
        severity: TaskSeverity::Low,
        suggested_fix: None,
        observe_issue_id: None,
    }
}

fn map_issue_severity(severity: IssueSeverity) -> TaskSeverity {
    match severity {
        IssueSeverity::Critical => TaskSeverity::Critical,
        IssueSeverity::Medium => TaskSeverity::Medium,
        IssueSeverity::Low => TaskSeverity::Low,
    }
}
