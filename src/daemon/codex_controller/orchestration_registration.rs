use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::CodexRunRequest;
use crate::daemon::service as daemon_service;
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as session_service;
use crate::session::types::{
    AgentRegistration, CONTROL_PLANE_ACTOR_ID, ManagedAgentRef, SessionRole, SessionState,
    TaskStatus, WorkItem,
};
use crate::workspace::utc_now;

use super::handle::{CodexControllerHandle, lock_db};
use super::orchestration::rollback_codex_registration;

#[derive(Clone, Debug)]
pub(super) struct RegistrationMutation {
    pub(super) newly_joined: bool,
    pub(super) task_binding_rollback: Option<TaskBindingRollback>,
}

#[derive(Clone, Debug)]
pub(super) struct TaskBindingRollback {
    pub(super) task: WorkItem,
    pub(super) agent: AgentRegistration,
    pub(super) bound_task: WorkItem,
    pub(super) bound_agent: AgentRegistration,
}

struct TaskBindingBefore {
    task: WorkItem,
    agent: AgentRegistration,
}

#[derive(Debug)]
pub(super) struct RegisteredOrchestrationAgent {
    pub(super) agent_id: String,
    pub(super) mutation: RegistrationMutation,
}

pub(super) fn register_async(
    controller: &CodexControllerHandle,
    session_id: &str,
    request: &CodexRunRequest,
    display_name: &str,
    managed_agent: &ManagedAgentRef,
) -> Option<Result<RegisteredOrchestrationAgent, CliError>> {
    let session_id = session_id.to_string();
    let display_name = display_name.to_string();
    let managed_agent = managed_agent.clone();
    let request = request.clone();
    controller.run_with_async_db(|async_db| async move {
        let now = utc_now();
        let registration = async_db
            .update_session_state_immediate(&session_id, |state| {
                let newly_joined = !state
                    .agents
                    .values()
                    .any(|agent| agent.matches_managed_agent(&managed_agent));
                let joined_role = session_service::resolve_join_role(
                    &*state,
                    request.role,
                    request.fallback_role,
                )?;
                let agent_id = session_service::apply_join_session(
                    &mut *state,
                    &display_name,
                    "codex",
                    joined_role,
                    &request.capabilities,
                    None,
                    &now,
                    request.persona.as_deref(),
                    Some(managed_agent.clone()),
                )?;
                let effective_role = state.agents[&agent_id].role;
                let task_binding_before = task_binding_before(
                    state,
                    request.task_id.as_deref(),
                    &agent_id,
                );
                bind_requested_task(state, request.task_id.as_deref(), &agent_id, &now)?;
                let task_binding_rollback = task_binding_rollback(
                    state,
                    &agent_id,
                    task_binding_before,
                );
                Ok((
                    agent_id,
                    effective_role,
                    RegistrationMutation {
                        newly_joined,
                        task_binding_rollback,
                    },
                ))
            })
            .await?;
        finalize_async_registration(
            &async_db,
            &session_id,
            &registration.0,
            registration.1,
            &managed_agent,
            &registration.2,
        )
        .await?;
        Ok(RegisteredOrchestrationAgent {
            agent_id: registration.0,
            mutation: registration.2,
        })
    })
}

pub(super) fn register_sync(
    controller: &CodexControllerHandle,
    session_id: &str,
    request: &CodexRunRequest,
    display_name: &str,
    managed_agent: &ManagedAgentRef,
) -> Result<RegisteredOrchestrationAgent, CliError> {
    let db = controller.db()?;
    let db = lock_db(&db)?;
    let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
        return Err(daemon_service::session_not_found(session_id));
    };
    let original_state = state.clone();
    let now = utc_now();
    let newly_joined = !state
        .agents
        .values()
        .any(|agent| agent.matches_managed_agent(managed_agent));
    let joined_role =
        session_service::resolve_join_role(&state, request.role, request.fallback_role)?;
    let agent_id = session_service::apply_join_session(
        &mut state,
        display_name,
        "codex",
        joined_role,
        &request.capabilities,
        None,
        &now,
        request.persona.as_deref(),
        Some(managed_agent.clone()),
    )?;
    let effective_role = state.agents[&agent_id].role;
    let task_binding_before =
        task_binding_before(&state, request.task_id.as_deref(), &agent_id);
    bind_requested_task(&mut state, request.task_id.as_deref(), &agent_id, &now)?;
    let task_binding_rollback =
        task_binding_rollback(&state, &agent_id, task_binding_before);
    let mutation = RegistrationMutation {
        newly_joined,
        task_binding_rollback,
    };
    if let Err(error) = persist_sync_registration(
        &db,
        session_id,
        &state,
        &agent_id,
        effective_role,
        newly_joined,
    ) {
        rollback_sync_registration(&db, session_id, &original_state);
        return Err(error);
    }
    Ok(RegisteredOrchestrationAgent { agent_id, mutation })
}

fn persist_sync_registration(
    db: &crate::daemon::db::DaemonDb,
    session_id: &str,
    state: &SessionState,
    agent_id: &str,
    joined_role: SessionRole,
    newly_joined: bool,
) -> Result<(), CliError> {
    let project_id = db
        .project_id_for_session(session_id)?
        .ok_or_else(|| daemon_service::session_not_found(session_id))?;
    db.save_session_state(&project_id, state)?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    if !newly_joined {
        return Ok(());
    }
    db.append_log_entry(&daemon_service::build_log_entry(
        session_id,
        session_service::log_agent_joined(agent_id, joined_role, "codex"),
        None,
        None,
    ))
}

fn rollback_sync_registration(
    db: &crate::daemon::db::DaemonDb,
    session_id: &str,
    original_state: &SessionState,
) {
    let restore_result = db
        .project_id_for_session(session_id)
        .and_then(|project_id| {
            project_id
                .ok_or_else(|| daemon_service::session_not_found(session_id))
        })
        .and_then(|project_id| db.save_session_state(&project_id, original_state));
    if let Err(error) = restore_result {
        tracing::warn!(
            %error,
            session_id,
            "failed to restore session after codex registration persistence failure"
        );
        return;
    }
    if let Err(error) = db.bump_change(session_id).and_then(|()| db.bump_change("global")) {
        tracing::warn!(
            %error,
            session_id,
            "failed to publish restored session after codex registration persistence failure"
        );
    }
}

pub(super) async fn finalize_async_registration(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    agent_id: &str,
    joined_role: SessionRole,
    managed_agent: &ManagedAgentRef,
    mutation: &RegistrationMutation,
) -> Result<(), CliError> {
    let result = persist_registration_side_effects(
        async_db,
        session_id,
        agent_id,
        joined_role,
        mutation.newly_joined,
    )
    .await;
    let Err(error) = result else {
        return Ok(());
    };
    if (mutation.newly_joined || mutation.task_binding_rollback.is_some())
        && let Err(rollback_error) = rollback_registration(
            async_db,
            session_id,
            agent_id,
            managed_agent,
            mutation,
        )
        .await
    {
        tracing::warn!(
            %rollback_error,
            session_id,
            agent_id,
            "failed to roll back codex registration after persistence failure"
        );
    }
    Err(error)
}

async fn persist_registration_side_effects(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    agent_id: &str,
    joined_role: SessionRole,
    newly_joined: bool,
) -> Result<(), CliError> {
    daemon_service::sync_file_state_from_async_db(async_db, session_id).await?;
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await?;
    if !newly_joined {
        return Ok(());
    }
    async_db
        .append_log_entry(&daemon_service::build_log_entry(
            session_id,
            session_service::log_agent_joined(agent_id, joined_role, "codex"),
            None,
            None,
        ))
        .await
}

async fn rollback_registration(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    agent_id: &str,
    managed_agent: &ManagedAgentRef,
    mutation: &RegistrationMutation,
) -> Result<(), CliError> {
    let now = utc_now();
    let removed = async_db
        .update_session_state_immediate(session_id, |state| {
            Ok(rollback_codex_registration(
                state,
                agent_id,
                managed_agent,
                mutation.newly_joined,
                mutation.task_binding_rollback.as_ref(),
                &now,
            ))
        })
        .await?;
    if removed {
        daemon_service::sync_file_state_from_async_db(async_db, session_id).await?;
        async_db.bump_change(session_id).await?;
        async_db.bump_change("global").await?;
    }
    Ok(())
}

fn task_binding_before(
    state: &SessionState,
    task_id: Option<&str>,
    agent_id: &str,
) -> Option<TaskBindingBefore> {
    let task = state.tasks.get(task_id?)?;
    if task.status == TaskStatus::InProgress
        && task.assigned_to.as_deref() == Some(agent_id)
    {
        return None;
    }
    let agent = state.agents.get(agent_id)?;
    Some(TaskBindingBefore {
        task: task.clone(),
        agent: agent.clone(),
    })
}

fn task_binding_rollback(
    state: &SessionState,
    agent_id: &str,
    before: Option<TaskBindingBefore>,
) -> Option<TaskBindingRollback> {
    let before = before?;
    let bound_task = state.tasks.get(&before.task.task_id)?.clone();
    let bound_agent = state.agents.get(agent_id)?;
    Some(TaskBindingRollback {
        task: before.task,
        agent: before.agent,
        bound_task,
        bound_agent: bound_agent.clone(),
    })
}

pub(super) fn bind_requested_task(
    state: &mut SessionState,
    task_id: Option<&str>,
    agent_id: &str,
    now: &str,
) -> Result<(), CliError> {
    let Some(task_id) = task_id else {
        return Ok(());
    };
    let task = state.tasks.get(task_id).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' not found in session '{}'",
            state.session_id
        )))
    })?;
    if task.status == TaskStatus::InProgress && task.assigned_to.as_deref() == Some(agent_id) {
        return Ok(());
    }
    if task.status != TaskStatus::Open
        || task.assigned_to.as_deref().is_some_and(|id| id != agent_id)
    {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' cannot be bound to agent '{agent_id}' from status {:?} and assignee {:?}",
            task.status, task.assigned_to
        ))
        .into());
    }
    let mut effects = Vec::new();
    session_service::start_task_for_agent(
        state,
        task_id,
        agent_id,
        CONTROL_PLANE_ACTOR_ID,
        now,
        &mut effects,
    )?;
    let start_signal = effects.into_iter().find_map(|effect| match effect {
        session_service::TaskDropEffect::Started(record) => Some(record.signal),
        session_service::TaskDropEffect::Queued { .. } => None,
    });
    let started = start_signal.as_ref().and_then(|signal| {
        session_service::apply_task_start_delivery(state, agent_id, signal, now)
    });
    if started.as_deref() != Some(task_id) {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "task '{task_id}' could not be started for agent '{agent_id}'"
        ))
        .into());
    }
    session_service::refresh_session(state, now);
    Ok(())
}
