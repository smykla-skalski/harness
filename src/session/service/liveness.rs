use super::{
    AgentRegistration, AgentStatus, CliError, LivenessConfig, Path, SessionState,
    SessionTransition, TaskQueuePolicy, TaskStatus, agent_runtime_session_id,
    clear_pending_leader_transfer, load_state_or_err, promote_or_degrade, read_pending_signals,
    refresh_session, require_active, runtime, signal_context_root,
    signal_dirs_for_agent_in_context_root, signal_matches_session, storage, utc_now,
};

/// Result of a liveness synchronization pass.
#[derive(Debug, Clone, Default)]
pub struct LivenessSyncResult {
    /// Agent IDs that were marked as disconnected (unresponsive).
    pub disconnected: Vec<String>,
    /// Agent IDs that were transitioned to idle.
    pub idled: Vec<String>,
}

/// Run a one-shot liveness reconciliation for all agents in a session.
///
/// For each alive agent, reads the runtime's actual log file mtime, updates
/// `last_activity_at` in session state, and transitions the agent's status
/// based on the configured liveness thresholds:
/// - Active: log activity within 30 seconds
/// - Idle: log activity between 30 and 300 seconds ago
/// - Disconnected: no log activity for 300+ seconds
///
/// When an agent transitions to `Disconnected`, any in-progress task assigned
/// to it is returned to `Open` so it can be reassigned.
///
/// # Errors
/// Returns `CliError` on storage or filesystem failures.
pub fn sync_agent_liveness(
    session_id: &str,
    project_dir: &Path,
) -> Result<LivenessSyncResult, CliError> {
    let now = utc_now();
    let mut result = LivenessSyncResult::default();
    let activity_map = collect_agent_activity(session_id, project_dir)?;
    let layout = storage::layout_from_project_dir(project_dir, session_id)?;

    storage::update_state_if_changed(&layout, |state| {
        require_active(state)?;
        let changed = apply_liveness_transitions(state, &activity_map, &now, &mut result);
        if changed {
            refresh_session(state, &now);
        }
        Ok(changed)
    })?;

    if !result.disconnected.is_empty() || !result.idled.is_empty() {
        let _ = storage::append_log_entry(
            &layout,
            SessionTransition::LivenessSynced {
                disconnected: result.disconnected.clone(),
                idled: result.idled.clone(),
            },
            None,
            Some("liveness sync"),
        );
    }

    cleanup_dead_agent_signals(&activity_map, &result, session_id, project_dir);
    Ok(result)
}

pub(crate) struct AgentActivityRecord {
    agent_id: String,
    last_activity: Option<String>,
    state_last_activity: Option<String>,
    runtime_name: String,
    agent_session_id: Option<String>,
    has_pending_signals: bool,
}

pub(crate) fn collect_agent_activity(
    session_id: &str,
    project_dir: &Path,
) -> Result<Vec<AgentActivityRecord>, CliError> {
    let state = load_state_or_err(session_id, project_dir)?;
    Ok(collect_agent_activity_from_state(
        &state,
        session_id,
        project_dir,
    ))
}

pub(crate) fn collect_agent_activity_from_state(
    state: &SessionState,
    session_id: &str,
    project_dir: &Path,
) -> Vec<AgentActivityRecord> {
    let mut records = Vec::new();
    let context_root = signal_context_root(project_dir);
    for agent in state.agents.values() {
        if !agent.status.is_alive() {
            continue;
        }
        let Some(agent_runtime) = runtime::runtime_for_name(&agent.runtime) else {
            continue;
        };
        let agent_session_id = agent_runtime_session_id(session_id, agent);
        let last_activity = agent_runtime
            .last_activity(project_dir, agent_session_id)
            .unwrap_or(None);
        records.push(AgentActivityRecord {
            agent_id: agent.agent_id.clone(),
            last_activity,
            state_last_activity: agent.last_activity_at.clone(),
            runtime_name: agent.runtime.clone(),
            agent_session_id: agent.agent_session_id.clone(),
            has_pending_signals: has_pending_signals(agent_runtime, state, agent, &context_root),
        });
    }
    records
}

pub(crate) fn apply_liveness_transitions(
    state: &mut SessionState,
    activity_map: &[AgentActivityRecord],
    now: &str,
    result: &mut LivenessSyncResult,
) -> bool {
    let mut changed = false;
    for record in activity_map {
        let config = LivenessConfig::for_runtime_name(&record.runtime_name);
        if let Some(transition) = compute_agent_transition(state, record, &config) {
            changed = true;
            apply_single_transition(state, record, transition, now, result);
        }
    }
    changed
}

pub(crate) fn compute_agent_transition(
    state: &SessionState,
    record: &AgentActivityRecord,
    config: &LivenessConfig,
) -> Option<AgentStatus> {
    use crate::agents::runtime::liveness::{LivenessStatus, liveness_from_timestamp};

    let agent = state.agents.get(&record.agent_id)?;
    if !agent.status.is_alive() {
        return None;
    }

    let effective_activity = most_recent_activity([
        record.last_activity.as_deref(),
        record.state_last_activity.as_deref(),
    ])
    .or(Some(agent.joined_at.as_str()));
    let mut new_status = match liveness_from_timestamp(effective_activity, config) {
        LivenessStatus::Active => AgentStatus::Active,
        LivenessStatus::Idle => AgentStatus::Idle,
        LivenessStatus::Unresponsive => AgentStatus::Disconnected,
    };
    if record.has_pending_signals && new_status == AgentStatus::Disconnected {
        new_status = AgentStatus::Idle;
    }

    if new_status == agent.status {
        None
    } else {
        Some(new_status)
    }
}

fn most_recent_activity<const N: usize>(candidates: [Option<&str>; N]) -> Option<&str> {
    candidates
        .into_iter()
        .flatten()
        .filter_map(|candidate| {
            chrono::DateTime::parse_from_rfc3339(candidate)
                .ok()
                .map(|parsed| (candidate, parsed))
        })
        .max_by(|left, right| left.1.cmp(&right.1))
        .map(|(candidate, _)| candidate)
}

fn has_pending_signals(
    agent_runtime: &dyn runtime::AgentRuntime,
    state: &SessionState,
    agent: &AgentRegistration,
    context_root: &Path,
) -> bool {
    signal_dirs_for_agent_in_context_root(
        agent_runtime,
        &state.session_id,
        agent.agent_session_id.as_deref(),
        context_root,
    )
    .into_iter()
    .any(|(signal_session_id, signal_dir)| {
        signal_dir_has_pending_session_signal(
            agent_runtime.name(),
            &signal_dir,
            &state.session_id,
            &agent.agent_id,
            &signal_session_id,
        )
    })
}

fn signal_dir_has_pending_session_signal(
    runtime_name: &str,
    signal_dir: &Path,
    session_id: &str,
    agent_id: &str,
    signal_session_id: &str,
) -> bool {
    match read_pending_signals(signal_dir) {
        Ok(pending) => pending.into_iter().any(|signal| {
            signal_matches_session(&signal, None, session_id, agent_id, signal_session_id)
        }),
        Err(error) => {
            warn_pending_signal_inspection_failure(runtime_name, signal_dir, agent_id, &error);
            true
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_pending_signal_inspection_failure(
    runtime_name: &str,
    signal_dir: &Path,
    agent_id: &str,
    error: &CliError,
) {
    tracing::warn!(
        %error,
        runtime = runtime_name,
        signal_dir = %signal_dir.display(),
        agent_id,
        "failed to inspect pending signals during liveness sync; keeping agent alive"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn apply_single_transition(
    state: &mut SessionState,
    record: &AgentActivityRecord,
    new_status: AgentStatus,
    now: &str,
    result: &mut LivenessSyncResult,
) {
    let Some(agent) = state.agents.get_mut(&record.agent_id) else {
        return;
    };

    if let Some(ref timestamp) = record.last_activity {
        agent.last_activity_at = Some(timestamp.clone());
    }

    let old_status = agent.status;
    agent.status = new_status;
    now.clone_into(&mut agent.updated_at);
    let was_leader = state.leader_id.as_deref() == Some(record.agent_id.as_str());

    if new_status == AgentStatus::Disconnected {
        release_agent_tasks(state, &record.agent_id, now);
        clear_pending_leader_transfer(state, &record.agent_id);
        if was_leader {
            promote_or_degrade(state, now);
        }
        result.disconnected.push(record.agent_id.clone());
        tracing::info!(
            agent_id = record.agent_id,
            ?old_status,
            "agent disconnected by liveness sync"
        );
    } else if new_status == AgentStatus::Idle {
        result.idled.push(record.agent_id.clone());
        tracing::debug!(agent_id = record.agent_id, "agent transitioned to idle");
    }
}

pub(crate) fn apply_agent_disconnected(
    state: &mut SessionState,
    agent_id: &str,
    now: &str,
) -> bool {
    let Some(current_status) = state.agents.get(agent_id).map(|agent| agent.status) else {
        return false;
    };
    if !current_status.is_alive() {
        return false;
    }

    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.status = AgentStatus::Disconnected;
        now.clone_into(&mut agent.updated_at);
        agent.last_activity_at = Some(now.to_string());
        agent.current_task_id = None;
    }
    let was_leader = state.leader_id.as_deref() == Some(agent_id);

    release_agent_tasks(state, agent_id, now);
    clear_pending_leader_transfer(state, agent_id);
    if was_leader {
        promote_or_degrade(state, now);
    }
    refresh_session(state, now);
    true
}

pub(crate) fn release_agent_tasks(state: &mut SessionState, agent_id: &str, now: &str) {
    // Clear current_task_id on the agent
    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.current_task_id = None;
    }
    // Return assigned tasks to Open
    for task in state.tasks.values_mut() {
        if task.assigned_to.as_deref() == Some(agent_id) && !matches!(task.status, TaskStatus::Done)
        {
            task.status = TaskStatus::Open;
            task.assigned_to = None;
            task.queue_policy = TaskQueuePolicy::Locked;
            task.queued_at = None;
            now.clone_into(&mut task.updated_at);
        }
    }
}

pub(crate) fn cleanup_dead_agent_signals(
    activity_map: &[AgentActivityRecord],
    result: &LivenessSyncResult,
    session_id: &str,
    project_dir: &Path,
) {
    use crate::agents::runtime::signal::cleanup_pending_signals;
    let context_root = signal_context_root(project_dir);

    for record in activity_map {
        if !result.disconnected.contains(&record.agent_id) {
            continue;
        }
        let Some(agent_runtime) = runtime::runtime_for_name(&record.runtime_name) else {
            continue;
        };
        if let Some(ref agent_session) = record.agent_session_id {
            let signal_dir = agent_runtime.signal_dir(&context_root, agent_session);
            let _ = cleanup_pending_signals(&signal_dir, &record.agent_id, session_id);
        }
        let signal_dir = agent_runtime.signal_dir(&context_root, session_id);
        let _ = cleanup_pending_signals(&signal_dir, &record.agent_id, session_id);
    }
}
