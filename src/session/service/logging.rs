use super::{
    AckResult, CliError, LeaveSignalRecord, Path, SessionRole, SessionTransition, TaskDropEffect,
    TaskSource, TaskSpec, TaskStartSignalRecord, TaskStatus, WorkItem, storage,
};

pub(crate) fn log_session_started(title: &str, context: &str) -> SessionTransition {
    SessionTransition::SessionStarted {
        title: title.to_string(),
        context: context.to_string(),
    }
}

pub(crate) fn log_agent_joined(
    agent_id: &str,
    role: SessionRole,
    runtime: &str,
) -> SessionTransition {
    SessionTransition::AgentJoined {
        agent_id: agent_id.to_string(),
        role,
        runtime: runtime.to_string(),
    }
}

pub(crate) fn log_session_ended() -> SessionTransition {
    SessionTransition::SessionEnded
}

pub(crate) fn log_role_changed(
    agent_id: &str,
    from: SessionRole,
    to: SessionRole,
) -> SessionTransition {
    SessionTransition::RoleChanged {
        agent_id: agent_id.to_string(),
        from,
        to,
    }
}

pub(crate) fn log_agent_removed(agent_id: &str) -> SessionTransition {
    SessionTransition::AgentRemoved {
        agent_id: agent_id.to_string(),
    }
}

pub(crate) fn log_agent_disconnected(agent_id: &str, reason: &str) -> SessionTransition {
    SessionTransition::AgentDisconnected {
        agent_id: agent_id.to_string(),
        reason: reason.to_string(),
    }
}

pub(crate) fn log_task_created(spec: &TaskSpec<'_>, item: &WorkItem) -> SessionTransition {
    if spec.source == TaskSource::Observe {
        SessionTransition::ObserveTaskCreated {
            task_id: item.task_id.clone(),
            title: item.title.clone(),
            severity: spec.severity,
            issue_id: spec.observe_issue_id.map(ToString::to_string),
        }
    } else {
        SessionTransition::TaskCreated {
            task_id: item.task_id.clone(),
            title: item.title.clone(),
            severity: spec.severity,
        }
    }
}

pub(crate) fn log_task_assigned(task_id: &str, agent_id: &str) -> SessionTransition {
    SessionTransition::TaskAssigned {
        task_id: task_id.to_string(),
        agent_id: agent_id.to_string(),
    }
}

pub(crate) fn log_task_queued(task_id: &str, agent_id: &str) -> SessionTransition {
    SessionTransition::TaskQueued {
        task_id: task_id.to_string(),
        agent_id: agent_id.to_string(),
    }
}

pub(crate) fn log_task_status_changed(
    task_id: &str,
    from: TaskStatus,
    to: TaskStatus,
) -> SessionTransition {
    SessionTransition::TaskStatusChanged {
        task_id: task_id.to_string(),
        from,
        to,
    }
}

pub(crate) fn log_checkpoint_recorded(
    task_id: &str,
    checkpoint_id: &str,
    progress: u8,
) -> SessionTransition {
    SessionTransition::TaskCheckpointRecorded {
        task_id: task_id.to_string(),
        checkpoint_id: checkpoint_id.to_string(),
        progress,
    }
}

pub(crate) fn log_signal_sent(signal_id: &str, agent_id: &str, command: &str) -> SessionTransition {
    SessionTransition::SignalSent {
        signal_id: signal_id.to_string(),
        agent_id: agent_id.to_string(),
        command: command.to_string(),
    }
}

pub(crate) fn log_signal_acknowledged(
    signal_id: &str,
    agent_id: &str,
    result: AckResult,
) -> SessionTransition {
    SessionTransition::SignalAcknowledged {
        signal_id: signal_id.to_string(),
        agent_id: agent_id.to_string(),
        result,
    }
}

pub(crate) fn append_leave_signal_logs(
    project_dir: &Path,
    session_id: &str,
    actor_id: &str,
    signals: &[LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        storage::append_log_entry(
            project_dir,
            session_id,
            log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            Some(actor_id),
            None,
        )?;
    }
    Ok(())
}

pub(crate) fn append_task_drop_effect_logs(
    project_dir: &Path,
    session_id: &str,
    actor_id: &str,
    effects: &[TaskDropEffect],
) -> Result<(), CliError> {
    for effect in effects {
        match effect {
            TaskDropEffect::Started(signal) => {
                storage::append_log_entry(
                    project_dir,
                    session_id,
                    log_signal_sent(
                        &signal.signal.signal_id,
                        &signal.agent_id,
                        &signal.signal.command,
                    ),
                    Some(actor_id),
                    None,
                )?;
            }
            TaskDropEffect::Queued { task_id, agent_id } => {
                storage::append_log_entry(
                    project_dir,
                    session_id,
                    log_task_queued(task_id, agent_id),
                    Some(actor_id),
                    None,
                )?;
            }
        }
    }
    Ok(())
}

pub(crate) fn started_task_signals(effects: &[TaskDropEffect]) -> Vec<TaskStartSignalRecord> {
    effects
        .iter()
        .filter_map(|effect| match effect {
            TaskDropEffect::Started(signal) => Some(signal.as_ref().clone()),
            TaskDropEffect::Queued { .. } => None,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Daemon response conversions
// ---------------------------------------------------------------------------
