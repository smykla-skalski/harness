use super::{
    AgentRegistration, AgentStatus, BTreeMap, CONTROL_PLANE_ACTOR_ID, CURRENT_VERSION, CliError,
    CliErrorKind, LEAVE_SESSION_SIGNAL_COMMAND, LeaveSignalRecord, Path, SessionAction,
    SessionMetrics, SessionRole, SessionState, SessionStatus, TaskStatus, agent_status_label,
    build_signal, fmt, generate_session_id, is_permitted, refresh_session, runtime,
    runtime_capabilities, storage,
};
use crate::session::types::SessionPolicy;

#[expect(
    clippy::too_many_arguments,
    reason = "session creation threads transport fields through file-backed persistence"
)]
pub(crate) fn create_initial_session(
    context: &str,
    title: &str,
    runtime_name: &str,
    session_id: Option<&str>,
    agent_session_id: Option<&str>,
    now: &str,
    project_dir: &Path,
    policy_preset: Option<&str>,
) -> Result<SessionState, CliError> {
    if let Some(session_id) = session_id
        .filter(|value| !value.trim().is_empty())
        .map(ToString::to_string)
    {
        let candidate = build_initial_state(
            context,
            title,
            &session_id,
            runtime_name,
            agent_session_id,
            now,
            policy_preset,
        );
        if !storage::create_state(project_dir, &session_id, &candidate)? {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "session '{session_id}' already exists"
            ))
            .into());
        }
        return Ok(candidate);
    }

    for _ in 0..8 {
        let session_id = generate_session_id();
        let candidate = build_initial_state(
            context,
            title,
            &session_id,
            runtime_name,
            agent_session_id,
            now,
            policy_preset,
        );
        if storage::create_state(project_dir, &session_id, &candidate)? {
            return Ok(candidate);
        }
    }

    Err(
        CliErrorKind::session_agent_conflict("failed to allocate a unique session ID".to_string())
            .into(),
    )
}

pub(crate) fn require_active(state: &SessionState) -> Result<(), CliError> {
    if state.status != SessionStatus::Active {
        return Err(CliErrorKind::session_not_active(format!(
            "session '{}' is {:?}",
            state.session_id, state.status
        ))
        .into());
    }
    Ok(())
}

pub(crate) fn ensure_session_can_end(state: &SessionState) -> Result<(), CliError> {
    let active_tasks = state.tasks.values().any(|task| {
        matches!(
            task.status,
            TaskStatus::InProgress | TaskStatus::InReview | TaskStatus::Blocked
        ) || (task.status == TaskStatus::Open && task.assigned_to.is_some())
    });
    if active_tasks {
        return Err(CliErrorKind::session_agent_conflict(
            "cannot end session with in-progress tasks",
        )
        .into());
    }
    Ok(())
}

pub(crate) fn require_removable_agent(
    state: &SessionState,
    agent_id: &str,
) -> Result<(), CliError> {
    if state.leader_id.as_deref() == Some(agent_id) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "cannot remove current leader '{agent_id}'; transfer leadership first"
        ))
        .into());
    }
    if !state.agents.contains_key(agent_id) {
        return Err(
            CliErrorKind::session_agent_conflict(format!("agent '{agent_id}' not found")).into(),
        );
    }
    Ok(())
}

pub(crate) fn require_permission(
    state: &SessionState,
    actor_id: &str,
    action: SessionAction,
) -> Result<(), CliError> {
    if actor_id == CONTROL_PLANE_ACTOR_ID {
        return Ok(());
    }
    let agent = state.agents.get(actor_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{actor_id}' not registered in session '{}'",
            state.session_id
        )))
    })?;
    if !agent.status.is_alive() {
        return Err(CliErrorKind::session_permission_denied(format!(
            "agent '{actor_id}' is {} in session '{}'",
            agent_status_label(agent.status),
            state.session_id
        ))
        .into());
    }
    if !is_permitted(agent.role, action) {
        return Err(CliErrorKind::session_permission_denied(format!(
            "{:?} cannot {:?} in session '{}'",
            agent.role, action, state.session_id
        ))
        .into());
    }
    Ok(())
}

pub(crate) fn build_leave_signal_record(
    state: &SessionState,
    agent: &AgentRegistration,
    actor_id: &str,
    message: &str,
    action_hint: &str,
    now: &str,
    action: &str,
) -> Result<LeaveSignalRecord, CliError> {
    if runtime::runtime_for_name(&agent.runtime).is_none() {
        return Err(leave_signal_delivery_error(
            action,
            &agent.agent_id,
            format!("unknown runtime '{}'", agent.runtime),
        ));
    }
    let signal_session_id = agent
        .agent_session_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&state.session_id)
        .to_string();
    Ok(LeaveSignalRecord {
        runtime: agent.runtime.clone(),
        agent_id: agent.agent_id.clone(),
        signal_session_id,
        signal: build_signal(
            actor_id,
            LEAVE_SESSION_SIGNAL_COMMAND,
            message,
            Some(action_hint),
            &state.session_id,
            &agent.agent_id,
            now,
        ),
    })
}

pub(crate) fn leave_signal_delivery_error(
    action: &str,
    agent_id: &str,
    detail: impl fmt::Display,
) -> CliError {
    CliErrorKind::session_agent_conflict(format!(
        "cannot {action}: leave signal delivery failed for agent '{agent_id}' ({detail}); session was not changed and needs attention before retry"
    ))
    .into()
}

pub(crate) fn build_initial_state(
    context: &str,
    title: &str,
    session_id: &str,
    runtime_name: &str,
    agent_session_id: Option<&str>,
    now: &str,
    policy_preset: Option<&str>,
) -> SessionState {
    let leader_id = format!("{runtime_name}-leader");
    let mut agents = BTreeMap::new();
    agents.insert(
        leader_id.clone(),
        AgentRegistration {
            agent_id: leader_id.clone(),
            name: format!("{runtime_name} leader"),
            runtime: runtime_name.to_string(),
            role: SessionRole::Leader,
            capabilities: Vec::new(),
            joined_at: now.to_string(),
            updated_at: now.to_string(),
            status: AgentStatus::Active,
            agent_session_id: agent_session_id.map(ToString::to_string),
            last_activity_at: Some(now.to_string()),
            current_task_id: None,
            runtime_capabilities: runtime_capabilities(runtime_name),
            persona: None,
        },
    );

    let mut state = SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 1,
        session_id: session_id.to_string(),
        title: title.to_string(),
        context: context.to_string(),
        status: SessionStatus::Active,
        policy: policy_for_preset(policy_preset),
        created_at: now.to_string(),
        updated_at: now.to_string(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: Some(leader_id),
        archived_at: None,
        last_activity_at: Some(now.to_string()),
        observe_id: Some(format!("observe-{session_id}")),
        pending_leader_transfer: None,
        metrics: SessionMetrics::default(),
    };
    refresh_session(&mut state, now);
    state
}

pub(crate) fn validate_policy_preset(policy_preset: Option<&str>) -> Result<(), CliError> {
    match policy_preset {
        None | Some("swarm-default") => Ok(()),
        Some(preset) => Err(CliErrorKind::session_agent_conflict(format!(
            "unknown session policy preset '{preset}'; supported presets: swarm-default"
        ))
        .into()),
    }
}

fn policy_for_preset(_policy_preset: Option<&str>) -> SessionPolicy {
    SessionPolicy::default()
}

pub(crate) fn require_active_target_agent(
    state: &SessionState,
    agent_id: &str,
) -> Result<(), CliError> {
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if !agent.status.is_alive() {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is {}",
            agent_status_label(agent.status)
        ))
        .into());
    }
    Ok(())
}

pub(crate) fn require_active_worker_target_agent(
    state: &SessionState,
    agent_id: &str,
) -> Result<(), CliError> {
    require_active_target_agent(state, agent_id)?;
    let agent = state.agents.get(agent_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' not found"
        )))
    })?;
    if agent.role != SessionRole::Worker {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{agent_id}' is a {:?}, not a worker",
            agent.role
        ))
        .into());
    }
    Ok(())
}
