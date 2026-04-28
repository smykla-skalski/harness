use super::{
    AckResult, AgentRegistration, BTreeMap, CliError, Path, PathBuf, START_TASK_SIGNAL_COMMAND,
    SessionSignalRecord, SessionSignalStatus, SessionState, Signal, SignalAck, TaskQueuePolicy,
    TaskStatus, clear_agent_current_task, load_state_or_err, project_context_dir,
    read_acknowledged_signals, read_acknowledgments, read_pending_signals,
    record_signal_acknowledgment, runtime, signal_matches_session, utc_now, write_signal_ack,
};

pub(crate) fn reconcile_expired_pending_signals(
    session_id: &str,
    project_dir: &Path,
) -> Result<(), CliError> {
    let expired = collect_expired_pending_signals(session_id, project_dir)?;
    for signal in expired {
        let ack = SignalAck {
            signal_id: signal.signal.signal_id.clone(),
            acknowledged_at: utc_now(),
            result: AckResult::Expired,
            agent: signal.signal_session_id.clone(),
            session_id: session_id.to_string(),
            details: Some("expired before agent acknowledged delivery".to_string()),
        };
        write_signal_ack(&signal.signal_dir, &ack)?;
        record_signal_acknowledgment(
            session_id,
            &signal.agent_id,
            &signal.signal.signal_id,
            AckResult::Expired,
            project_dir,
        )?;
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub(crate) struct ExpiredPendingSignal {
    pub(crate) agent_id: String,
    pub(crate) signal_session_id: String,
    pub(crate) signal_dir: PathBuf,
    pub(crate) signal: Signal,
}

pub(crate) fn collect_expired_pending_signals(
    session_id: &str,
    project_dir: &Path,
) -> Result<Vec<ExpiredPendingSignal>, CliError> {
    let state = load_state_or_err(session_id, project_dir)?;
    collect_expired_pending_signals_for_state(&state, project_dir)
}

pub(crate) fn collect_expired_pending_signals_for_state(
    state: &SessionState,
    project_dir: &Path,
) -> Result<Vec<ExpiredPendingSignal>, CliError> {
    collect_expired_pending_signals_for_state_with_context_root_resolver(
        state,
        project_dir,
        signal_context_root,
    )
}

pub(crate) fn collect_expired_pending_signals_for_state_with_context_root_resolver<F>(
    state: &SessionState,
    project_dir: &Path,
    context_root_resolver: F,
) -> Result<Vec<ExpiredPendingSignal>, CliError>
where
    F: FnOnce(&Path) -> PathBuf,
{
    let context_root = context_root_resolver(project_dir);
    collect_expired_pending_signals_for_state_in_context_root(state, &context_root)
}

pub(crate) fn collect_expired_pending_signals_for_state_in_context_root(
    state: &SessionState,
    context_root: &Path,
) -> Result<Vec<ExpiredPendingSignal>, CliError> {
    let mut expired_by_id = BTreeMap::new();

    for (agent_id, agent) in &state.agents {
        let Some(runtime) = runtime::runtime_for_name(agent.runtime.runtime_name()) else {
            continue;
        };
        for (signal_session_id, signal_dir) in signal_dirs_for_agent_in_context_root(
            runtime,
            &state.session_id,
            agent.agent_session_id.as_deref(),
            context_root,
        ) {
            for signal in read_pending_signals(&signal_dir)? {
                if !signal_matches_session(
                    &signal,
                    None,
                    &state.session_id,
                    agent_id,
                    &signal_session_id,
                ) || !signal_is_expired(&signal.expires_at)
                {
                    continue;
                }
                expired_by_id
                    .entry(signal.signal_id.clone())
                    .or_insert_with(|| ExpiredPendingSignal {
                        agent_id: agent_id.clone(),
                        signal_session_id: signal_session_id.clone(),
                        signal_dir: signal_dir.clone(),
                        signal,
                    });
            }
        }
    }

    Ok(expired_by_id.into_values().collect())
}

pub(crate) fn signal_context_root(project_dir: &Path) -> PathBuf {
    project_context_dir(project_dir)
}

fn signal_dir_in_context_root(
    runtime: &dyn runtime::AgentRuntime,
    context_root: &Path,
    signal_session_id: &str,
) -> PathBuf {
    context_root
        .join("agents")
        .join("signals")
        .join(runtime.name())
        .join(signal_session_id)
}

pub(crate) fn signal_dirs_for_agent_in_context_root(
    runtime: &dyn runtime::AgentRuntime,
    orchestration_session_id: &str,
    agent_session_id: Option<&str>,
    context_root: &Path,
) -> Vec<(String, PathBuf)> {
    runtime::signal_session_keys(orchestration_session_id, agent_session_id)
        .into_iter()
        .map(|signal_session_id| {
            let signal_dir = signal_dir_in_context_root(runtime, context_root, &signal_session_id);
            (signal_session_id, signal_dir)
        })
        .collect()
}

pub(crate) fn agent_runtime_session_id<'a>(
    orchestration_session_id: &'a str,
    agent: &'a AgentRegistration,
) -> &'a str {
    agent
        .agent_session_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(orchestration_session_id)
}

pub(crate) fn runtime_session_matches_agent(
    orchestration_session_id: &str,
    agent: &AgentRegistration,
    runtime_session_id: &str,
) -> bool {
    agent_runtime_session_id(orchestration_session_id, agent) == runtime_session_id
}

pub(crate) fn load_signal_record_for_agent(
    session_id: &str,
    agent_id: &str,
    signal_id: &str,
    project_dir: &Path,
) -> Result<Option<SessionSignalRecord>, CliError> {
    let state = load_state_or_err(session_id, project_dir)?;
    load_signal_record_for_agent_from_state(&state, agent_id, signal_id, project_dir)
}

pub(crate) fn load_signal_record_for_agent_from_state(
    state: &SessionState,
    agent_id: &str,
    signal_id: &str,
    project_dir: &Path,
) -> Result<Option<SessionSignalRecord>, CliError> {
    let Some(agent) = state.agents.get(agent_id) else {
        return Ok(None);
    };
    let Some(runtime) = runtime::runtime_for_name(agent.runtime.runtime_name()) else {
        return Ok(None);
    };
    let context_root = signal_context_root(project_dir);
    let signal_dirs = signal_dirs_for_agent_in_context_root(
        runtime,
        &state.session_id,
        agent.agent_session_id.as_deref(),
        &context_root,
    );
    Ok(signal_records_for_dirs(
        agent.runtime.runtime_name(),
        agent_id,
        &state.session_id,
        &signal_dirs,
    )?
    .into_iter()
    .find(|record| record.signal.signal_id == signal_id))
}

pub(crate) fn normalize_signal_ack_result(signal: &Signal, result: AckResult) -> AckResult {
    match result {
        AckResult::Accepted if signal_is_expired(&signal.expires_at) => AckResult::Expired,
        _ => result,
    }
}

pub(crate) fn apply_signal_ack_result(
    state: &mut SessionState,
    agent_id: &str,
    signal: &Signal,
    result: AckResult,
    now: &str,
) -> Option<String> {
    match result {
        AckResult::Accepted => apply_task_start_delivery(state, agent_id, signal, now),
        AckResult::Expired => {
            expire_task_start_delivery(state, agent_id, signal, now);
            None
        }
        AckResult::Rejected | AckResult::Deferred => None,
    }
}

pub(crate) fn apply_task_start_delivery(
    state: &mut SessionState,
    agent_id: &str,
    signal: &Signal,
    now: &str,
) -> Option<String> {
    let task_id = task_id_for_task_start_signal(signal)?;
    let previous_assignee = state.tasks.get(task_id)?.assigned_to.clone();
    if let Some(previous_assignee) = previous_assignee.as_deref()
        && previous_assignee != agent_id
    {
        clear_agent_current_task(state, previous_assignee, task_id, now);
    }

    let task = state.tasks.get_mut(task_id)?;
    if matches!(
        task.status,
        TaskStatus::Done | TaskStatus::Blocked | TaskStatus::InReview
    ) {
        return None;
    }
    let started = task.status != TaskStatus::InProgress;
    task.assigned_to = Some(agent_id.to_string());
    task.status = TaskStatus::InProgress;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.blocked_reason = None;
    task.completed_at = None;
    task.updated_at = now.to_string();

    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.current_task_id = Some(task_id.to_string());
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }

    started.then(|| task_id.to_string())
}

pub(crate) fn expire_task_start_delivery(
    state: &mut SessionState,
    agent_id: &str,
    signal: &Signal,
    now: &str,
) {
    let Some(task_id) = task_id_for_task_start_signal(signal) else {
        return;
    };
    let Some(task) = state.tasks.get_mut(task_id) else {
        return;
    };
    if matches!(
        task.status,
        TaskStatus::Done | TaskStatus::Blocked | TaskStatus::InReview
    ) {
        return;
    }
    if task.assigned_to.as_deref() != Some(agent_id) {
        return;
    }

    task.assigned_to = None;
    task.status = TaskStatus::Open;
    task.queue_policy = TaskQueuePolicy::Locked;
    task.queued_at = None;
    task.blocked_reason = None;
    task.completed_at = None;
    task.updated_at = now.to_string();
    clear_agent_current_task(state, agent_id, task_id, now);
}

pub(crate) fn task_id_for_task_start_signal(signal: &Signal) -> Option<&str> {
    if signal.command != START_TASK_SIGNAL_COMMAND {
        return None;
    }
    let task_id = signal
        .payload
        .action_hint
        .as_deref()?
        .strip_prefix("task:")?;
    let prefix = format!("Start work on task {task_id}:");
    signal
        .payload
        .message
        .starts_with(&prefix)
        .then_some(task_id)
}

pub(crate) fn signal_is_expired(expires_at: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(expires_at)
        .is_ok_and(|expires| expires < chrono::Utc::now())
}

pub(crate) fn signal_records_for_dirs(
    runtime_name: &str,
    agent_id: &str,
    session_id: &str,
    signal_dirs: &[(String, PathBuf)],
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let mut signals_by_id = BTreeMap::new();
    let mut acknowledgments_by_id = BTreeMap::new();

    for (signal_session_id, signal_dir) in signal_dirs {
        for signal in read_pending_signals(signal_dir)? {
            signals_by_id.entry(signal.signal_id.clone()).or_insert((
                signal,
                false,
                signal_session_id.clone(),
            ));
        }
        for signal in read_acknowledged_signals(signal_dir)? {
            signals_by_id.insert(
                signal.signal_id.clone(),
                (signal, true, signal_session_id.clone()),
            );
        }
        for acknowledgment in read_acknowledgments(signal_dir)? {
            acknowledgments_by_id
                .entry(acknowledgment.signal_id.clone())
                .or_insert(acknowledgment);
        }
    }

    Ok(signals_by_id
        .into_values()
        .filter_map(|(signal, was_acknowledged, signal_session_id)| {
            let acknowledgment = acknowledgments_by_id.remove(&signal.signal_id);
            if !signal_matches_session(
                &signal,
                acknowledgment.as_ref(),
                session_id,
                agent_id,
                &signal_session_id,
            ) {
                return None;
            }
            let status = acknowledgment.as_ref().map_or_else(
                || {
                    if was_acknowledged {
                        SessionSignalStatus::Delivered
                    } else {
                        SessionSignalStatus::Pending
                    }
                },
                |ack| SessionSignalStatus::from_ack_result(ack.result),
            );
            Some(SessionSignalRecord {
                runtime: runtime_name.to_string(),
                agent_id: agent_id.to_string(),
                session_id: session_id.to_string(),
                status,
                signal,
                acknowledgment,
            })
        })
        .collect())
}
