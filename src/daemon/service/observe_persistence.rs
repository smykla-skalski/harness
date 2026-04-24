use std::collections::HashSet;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
#[cfg(test)]
use crate::observe::types::IssueCode;
use crate::observe::types::Issue;
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
        severity: task_severity_for_issue(issue),
        suggested_fix: issue.fix_hint.clone(),
        observe_issue_id: Some(issue.id.clone()),
    }
}

// Shared implementation lives in `session::observe::task_severity_for_issue`.
pub(crate) use crate::session::observe::task_severity_for_issue;

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


/// Inject a synthetic classifier issue and auto-file it as a task using
/// the same code path as production observer persistence. Crate-test
/// only; returns the resulting [`WorkItem`] for assertion.
#[cfg(test)]
pub(crate) fn test_inject_issue(
    state: &mut crate::session::types::SessionState,
    agent_id: &str,
    code: IssueCode,
    now: &str,
) -> Result<crate::session::types::WorkItem, CliError> {
    use crate::observe::types::{
        Confidence, FixSafety, IssueCategory, IssueSeverity, MessageRole,
    };

    let issue = Issue {
        id: format!("{code}/{agent_id}/1"),
        line: 1,
        code,
        category: IssueCategory::UnexpectedBehavior,
        severity: IssueSeverity::Medium,
        confidence: Confidence::Medium,
        fix_safety: FixSafety::TriageRequired,
        summary: format!("synthetic {code}"),
        details: String::new(),
        fingerprint: code.to_string(),
        source_role: MessageRole::Assistant,
        source_tool: None,
        fix_target: None,
        fix_hint: None,
        evidence_excerpt: None,
    };
    let spec_owned = issue_task_spec(&issue);
    let spec = session_service::TaskSpec {
        title: &spec_owned.title,
        context: spec_owned.context.as_deref(),
        severity: spec_owned.severity,
        suggested_fix: spec_owned.suggested_fix.as_deref(),
        source: TaskSource::Observe,
        observe_issue_id: spec_owned.observe_issue_id.as_deref(),
    };
    session_service::apply_create_task(state, &spec, agent_id, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observe::types::{
        Confidence, FixSafety, IssueCategory, IssueSeverity, MessageRole,
    };
    use crate::session::types::{
        AgentRegistration, AgentStatus, SessionMetrics, SessionPolicy, SessionRole, SessionState,
        SessionStatus,
    };
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    fn issue_with_code(code: IssueCode, severity: IssueSeverity) -> Issue {
        Issue {
            id: format!("{code}/x/1"),
            line: 1,
            code,
            category: IssueCategory::UnexpectedBehavior,
            severity,
            confidence: Confidence::Medium,
            fix_safety: FixSafety::TriageRequired,
            summary: "s".into(),
            details: String::new(),
            fingerprint: code.to_string(),
            source_role: MessageRole::Assistant,
            source_tool: None,
            fix_target: None,
            fix_hint: None,
            evidence_excerpt: None,
        }
    }

    #[test]
    fn task_severity_for_issue_overrides_python_traceback_to_high() {
        let issue = issue_with_code(IssueCode::PythonTracebackOutput, IssueSeverity::Medium);
        assert_eq!(task_severity_for_issue(&issue), TaskSeverity::High);
    }

    #[test]
    fn task_severity_for_issue_overrides_hook_denied_to_high() {
        let issue = issue_with_code(IssueCode::HookDeniedToolCall, IssueSeverity::Medium);
        assert_eq!(task_severity_for_issue(&issue), TaskSeverity::High);
    }

    #[test]
    fn task_severity_for_issue_overrides_recursive_remove_to_critical() {
        let issue = issue_with_code(IssueCode::UnverifiedRecursiveRemove, IssueSeverity::Medium);
        assert_eq!(task_severity_for_issue(&issue), TaskSeverity::Critical);
    }

    #[test]
    fn task_severity_for_issue_preserves_base_mapping_for_other_codes() {
        let issue = issue_with_code(IssueCode::JqErrorInCommandOutput, IssueSeverity::Medium);
        assert_eq!(task_severity_for_issue(&issue), TaskSeverity::Medium);
        let issue_low = issue_with_code(IssueCode::JqErrorInCommandOutput, IssueSeverity::Low);
        assert_eq!(task_severity_for_issue(&issue_low), TaskSeverity::Low);
    }

    fn base_state() -> SessionState {
        let mut state = SessionState {
            schema_version: 10,
            state_version: 1,
            session_id: "sess-inject".to_string(),
            project_name: String::new(),
            worktree_path: PathBuf::new(),
            shared_path: PathBuf::new(),
            origin_path: PathBuf::new(),
            branch_ref: "harness/sess-inject".to_string(),
            title: "t".into(),
            context: "c".into(),
            status: SessionStatus::Active,
            policy: SessionPolicy::default(),
            created_at: "now".into(),
            updated_at: "now".into(),
            agents: BTreeMap::new(),
            tasks: BTreeMap::new(),
            leader_id: Some("leader".into()),
            archived_at: None,
            last_activity_at: None,
            observe_id: None,
            pending_leader_transfer: None,
            external_origin: None,
            adopted_at: None,
            metrics: SessionMetrics::default(),
        };
        state.agents.insert(
            "leader".into(),
            AgentRegistration {
                agent_id: "leader".into(),
                name: "leader".into(),
                runtime: "claude".into(),
                role: SessionRole::Leader,
                capabilities: Vec::new(),
                joined_at: "now".into(),
                updated_at: "now".into(),
                status: AgentStatus::Active,
                agent_session_id: None,
                last_activity_at: None,
                current_task_id: None,
                runtime_capabilities: Default::default(),
                persona: None,
            },
        );
        state
    }

    #[test]
    fn test_inject_issue_creates_task_with_issue_aware_severity() {
        let mut state = base_state();
        let task = test_inject_issue(
            &mut state,
            "leader",
            IssueCode::PythonTracebackOutput,
            "2026-04-24T00:00:00Z",
        )
        .expect("inject");
        assert_eq!(task.severity, TaskSeverity::High);
        assert_eq!(task.source, TaskSource::Observe);
        assert!(task.observe_issue_id.as_deref().unwrap().starts_with("python_traceback_output/"));
    }
}
