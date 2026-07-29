use super::signals::pending_signal_record;
use super::{CliError, Path, SessionSignalRecord, session_service};

pub(crate) fn task_drop_effect_signal_records(
    session_id: &str,
    effects: &[session_service::TaskDropEffect],
) -> Vec<SessionSignalRecord> {
    effects
        .iter()
        .filter_map(|effect| match effect {
            session_service::TaskDropEffect::Started(signal) => Some(pending_signal_record(
                session_id,
                &signal.runtime,
                &signal.agent_id,
                &signal.signal,
            )),
            session_service::TaskDropEffect::Queued { .. } => None,
        })
        .collect()
}

pub(crate) fn write_task_start_signals(
    project_dir: &Path,
    effects: &[session_service::TaskDropEffect],
) -> Result<(), CliError> {
    let signals: Vec<_> = effects
        .iter()
        .filter_map(|effect| match effect {
            session_service::TaskDropEffect::Started(signal) => Some(signal.as_ref().clone()),
            session_service::TaskDropEffect::Queued { .. } => None,
        })
        .collect();
    session_service::write_prepared_task_start_signals(project_dir, &signals)
}
