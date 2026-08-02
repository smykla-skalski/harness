use crate::daemon::db::DaemonDb;

use super::{CliError, SessionLogEntry, SessionTransition, session_service, utc_now};
use crate::daemon::db::prelude::*;

pub(crate) fn append_leave_signal_logs_to_db(
    db: &DaemonDb,
    session_id: &str,
    actor_id: &str,
    signals: &[session_service::LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            Some(actor_id),
            None,
        ))?;
    }
    Ok(())
}

pub(crate) fn append_task_drop_effect_logs(
    db: &DaemonDb,
    session_id: &str,
    actor_id: &str,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    for effect in effects {
        match effect {
            session_service::TaskDropEffect::Started(signal) => {
                db.append_log_entry(&build_log_entry(
                    session_id,
                    session_service::log_signal_sent(
                        &signal.signal.signal_id,
                        &signal.agent_id,
                        &signal.signal.command,
                    ),
                    Some(actor_id),
                    None,
                ))?;
            }
            session_service::TaskDropEffect::Queued { task_id, agent_id } => {
                db.append_log_entry(&build_log_entry(
                    session_id,
                    session_service::log_task_queued(task_id, agent_id),
                    Some(actor_id),
                    None,
                ))?;
            }
        }
    }
    Ok(())
}

pub(crate) fn build_log_entry(
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> SessionLogEntry {
    SessionLogEntry {
        sequence: 0,
        recorded_at: utc_now(),
        session_id: session_id.to_string(),
        transition,
        actor_id: actor_id.map(ToString::to_string),
        reason: reason.map(ToString::to_string),
    }
}
