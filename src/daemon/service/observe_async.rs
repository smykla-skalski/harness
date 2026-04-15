use std::collections::{HashMap, HashSet};

use tokio::time::sleep;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::index::ResolvedSession;
use crate::observe::types::{Issue, IssueSeverity};
use crate::session::types::{SessionStatus, TaskSeverity, TaskSource};

use super::{
    CliError, Duration, ObserveSessionRequest, Path, PathBuf, SessionDetail, build_log_entry,
    effective_project_dir, session_detail_from_async_daemon_db, session_not_found, session_observe,
    session_service, start_daemon_observe_loop, sync_resolved_liveness_async, utc_now,
};

const SWEEP_CYCLE_COUNT: u64 = 100;

#[derive(Default)]
struct ObserveWatchState {
    realtime_seen: HashSet<String>,
    total_issues: usize,
    cycle_count: u64,
    tail_states: HashMap<String, session_observe::AgentLogTailState>,
    shared_cross_agent_editors: HashMap<String, HashSet<String>>,
}

struct ObserveTaskSpec {
    title: String,
    context: Option<String>,
    severity: TaskSeverity,
    suggested_fix: Option<String>,
    observe_issue_id: Option<String>,
}

/// Run a one-shot observe scan and persist daemon-owned mutations directly to
/// the canonical async DB.
///
/// # Errors
/// Returns [`CliError`] when the session cannot be resolved, log scanning
/// fails, or canonical persistence fails.
pub(crate) async fn observe_session_async(
    session_id: &str,
    request: Option<&ObserveSessionRequest>,
    async_db: &AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let actor_id = observe_actor_id(request);
    let mut resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let issues = session_observe::scan_all_agents(&resolved.state, session_id, &project_dir)?;
    apply_issue_tasks(async_db, &mut resolved, actor_id, &issues).await?;
    async_db.sync_runtime_transcripts(&resolved).await?;
    let _ = start_daemon_observe_loop(session_id, &project_dir, actor_id);
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Run the daemon-owned async observe watch loop with direct canonical writes.
///
/// # Errors
/// Returns [`CliError`] when runtime scanning or canonical persistence fails.
pub(crate) async fn run_daemon_observe_task_async(
    session_id: String,
    project_dir: PathBuf,
    poll_interval: Duration,
    actor_id: Option<String>,
    async_db: &AsyncDaemonDb,
) -> Result<i32, CliError> {
    let mut cycle = ObserveWatchState::default();
    loop {
        if !watch_cycle_async(
            &session_id,
            &project_dir,
            actor_id.as_deref(),
            async_db,
            &mut cycle,
        )
        .await?
        {
            break;
        }
        sleep(poll_interval).await;
    }

    Ok(i32::from(cycle.total_issues > 0))
}

async fn watch_cycle_async(
    session_id: &str,
    project_dir: &Path,
    actor_id: Option<&str>,
    async_db: &AsyncDaemonDb,
    cycle: &mut ObserveWatchState,
) -> Result<bool, CliError> {
    let Some(mut resolved) = resolve_active_session(async_db, session_id).await? else {
        return Ok(false);
    };
    let liveness_changed =
        sync_resolved_liveness_async(async_db, &mut resolved, project_dir).await?;
    let logs_changed =
        process_incremental_observe(async_db, &mut resolved, actor_id, project_dir, cycle).await?;
    cycle.cycle_count += 1;
    if cycle.cycle_count.is_multiple_of(SWEEP_CYCLE_COUNT) {
        run_periodic_sweep_async(async_db, &mut resolved, actor_id, project_dir, cycle).await?;
    }
    sync_runtime_transcripts_if_changed(async_db, &resolved, logs_changed || liveness_changed)
        .await?;
    Ok(true)
}

async fn resolve_active_session(
    async_db: &AsyncDaemonDb,
    session_id: &str,
) -> Result<Option<ResolvedSession>, CliError> {
    let resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    if resolved.state.status == SessionStatus::Active {
        Ok(Some(resolved))
    } else {
        Ok(None)
    }
}

async fn process_incremental_observe(
    async_db: &AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    project_dir: &Path,
    cycle: &mut ObserveWatchState,
) -> Result<bool, CliError> {
    let offsets_before = tail_offsets(&cycle.tail_states);
    let issues = session_observe::scan_all_agents_incremental(
        &resolved.state,
        &resolved.state.session_id,
        project_dir,
        &mut cycle.tail_states,
        &mut cycle.shared_cross_agent_editors,
    )?;
    let new_issues = issues
        .into_iter()
        .filter(|issue| cycle.realtime_seen.insert(issue.fingerprint.clone()))
        .collect::<Vec<_>>();
    if !new_issues.is_empty() {
        cycle.total_issues += new_issues.len();
        apply_issue_tasks(async_db, resolved, actor_id, &new_issues).await?;
    }
    Ok(tail_offsets_changed(&offsets_before, &cycle.tail_states))
}

async fn sync_runtime_transcripts_if_changed(
    async_db: &AsyncDaemonDb,
    resolved: &ResolvedSession,
    changed: bool,
) -> Result<(), CliError> {
    if changed {
        async_db.sync_runtime_transcripts(resolved).await?;
    }
    Ok(())
}

async fn run_periodic_sweep_async(
    async_db: &AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    project_dir: &Path,
    cycle: &mut ObserveWatchState,
) -> Result<(), CliError> {
    let sweep_issues =
        session_observe::scan_all_agents(&resolved.state, &resolved.state.session_id, project_dir)?;
    let missed: Vec<Issue> = sweep_issues
        .into_iter()
        .filter(|issue| !cycle.realtime_seen.contains(&issue.fingerprint))
        .collect();
    if missed.is_empty() {
        return Ok(());
    }

    cycle.total_issues += missed.len();
    apply_issue_tasks(async_db, resolved, actor_id, &missed).await?;
    apply_heuristic_gap_tasks(async_db, resolved, actor_id, &missed)
        .await
        .map(|_| ())
}

async fn apply_issue_tasks(
    async_db: &AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    let task_specs: Vec<_> = issues.iter().map(issue_task_spec).collect();
    apply_task_specs(async_db, resolved, actor_id, &task_specs).await
}

async fn apply_heuristic_gap_tasks(
    async_db: &AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    issues: &[Issue],
) -> Result<usize, CliError> {
    let task_specs: Vec<_> = issues.iter().map(heuristic_gap_task_spec).collect();
    apply_task_specs(async_db, resolved, actor_id, &task_specs).await
}

async fn apply_task_specs(
    async_db: &AsyncDaemonDb,
    resolved: &mut ResolvedSession,
    actor_id: Option<&str>,
    task_specs: &[ObserveTaskSpec],
) -> Result<usize, CliError> {
    let Some(actor_id) = actor_id.filter(|value| !value.trim().is_empty()) else {
        return Ok(0);
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

    if created_logs.is_empty() {
        return Ok(0);
    }

    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    for entry in &created_logs {
        async_db.append_log_entry(entry).await?;
    }
    bump_session(async_db, &resolved.state.session_id).await?;
    Ok(created_logs.len())
}

async fn bump_session(async_db: &AsyncDaemonDb, session_id: &str) -> Result<(), CliError> {
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

fn observe_actor_id(request: Option<&ObserveSessionRequest>) -> Option<&str> {
    request
        .and_then(|request| request.actor.as_deref())
        .filter(|value| !value.trim().is_empty())
}

fn tail_offsets(
    tail_states: &HashMap<String, session_observe::AgentLogTailState>,
) -> HashMap<String, u64> {
    tail_states
        .iter()
        .map(|(agent_id, state)| (agent_id.clone(), state.offset))
        .collect()
}

fn tail_offsets_changed(
    before: &HashMap<String, u64>,
    after: &HashMap<String, session_observe::AgentLogTailState>,
) -> bool {
    before.len() != after.len()
        || after
            .iter()
            .any(|(agent_id, state)| before.get(agent_id).copied() != Some(state.offset))
}
