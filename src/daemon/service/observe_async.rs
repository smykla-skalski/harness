use std::collections::{HashMap, HashSet};

use tokio::time::sleep;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::index::ResolvedSession;
use crate::observe::types::Issue;
use crate::session::types::SessionStatus;

use super::{
    CliError, Duration, ObserveSessionRequest, Path, PathBuf, SessionDetail,
    apply_heuristic_gap_tasks_to_async_db, apply_issue_tasks_to_async_db, effective_project_dir,
    observe_actor_id, session_detail_from_async_daemon_db, session_not_found, session_observe,
    start_daemon_observe_loop, sync_resolved_liveness_async,
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
    apply_issue_tasks_to_async_db(async_db, &mut resolved, actor_id, &issues).await?;
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
        apply_issue_tasks_to_async_db(async_db, resolved, actor_id, &new_issues).await?;
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
    apply_issue_tasks_to_async_db(async_db, resolved, actor_id, &missed).await?;
    apply_heuristic_gap_tasks_to_async_db(async_db, resolved, actor_id, &missed)
        .await
        .map(|_| ())
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
