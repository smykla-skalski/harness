use std::collections::BTreeMap;

use super::super::index::{self, DiscoveredProject, ResolvedSession};
use crate::agents::runtime::signal::{
    read_acknowledged_signals, read_acknowledgments, read_pending_signals, signal_matches_session,
};
use crate::agents::runtime::signal_session_keys;
use crate::daemon::db::DaemonDb;
use crate::errors::CliError;
use crate::session::types::{SessionSignalRecord, SessionSignalStatus, SessionState};

pub(super) fn load_signals_for_resolved(
    resolved: &ResolvedSession,
    db: Option<&DaemonDb>,
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let file_signals = || load_signals_for(&resolved.project, &resolved.state);

    let Some(db) = db else {
        return file_signals();
    };

    let indexed_signals = db.load_signals(&resolved.state.session_id)?;
    let should_refresh_from_files =
        indexed_signals.is_empty() || db.session_has_shared_runtime_signal_dir(&resolved.state)?;

    if !should_refresh_from_files {
        return Ok(indexed_signals);
    }

    let signals = file_signals()?;
    db.sync_signal_index(&resolved.state.session_id, &signals)?;
    Ok(signals)
}

/// Load signal records for a session from filesystem directories.
///
/// # Errors
/// Returns [`CliError`] on filesystem read failures.
#[expect(
    clippy::cognitive_complexity,
    reason = "signal snapshot assembly merges pending, acknowledged, and ack-result lanes in one pass"
)]
pub fn load_signals_for(
    project: &DiscoveredProject,
    state: &SessionState,
) -> Result<Vec<SessionSignalRecord>, CliError> {
    let mut signals = Vec::new();
    let root = index::signals_root(&project.context_root);
    for (agent_id, agent) in &state.agents {
        let mut signals_by_id = BTreeMap::new();
        let mut acknowledgments_by_id = BTreeMap::new();
        for signal_session_id in
            signal_session_keys(&state.session_id, agent.agent_session_id.as_deref())
        {
            let signal_dir = root.join(&agent.runtime).join(&signal_session_id);
            for signal in read_pending_signals(&signal_dir)? {
                signals_by_id.entry(signal.signal_id.clone()).or_insert((
                    signal,
                    false,
                    signal_session_id.clone(),
                ));
            }
            for signal in read_acknowledged_signals(&signal_dir)? {
                signals_by_id.insert(
                    signal.signal_id.clone(),
                    (signal, true, signal_session_id.clone()),
                );
            }
            for acknowledgment in read_acknowledgments(&signal_dir)? {
                acknowledgments_by_id
                    .entry(acknowledgment.signal_id.clone())
                    .or_insert(acknowledgment);
            }
        }

        for (signal, was_acknowledged, signal_session_id) in signals_by_id.into_values() {
            let acknowledgment = acknowledgments_by_id.remove(&signal.signal_id);
            if !signal_matches_session(
                &signal,
                acknowledgment.as_ref(),
                &state.session_id,
                agent_id,
                &signal_session_id,
            ) {
                continue;
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
            signals.push(SessionSignalRecord {
                runtime: agent.runtime.clone(),
                agent_id: agent_id.clone(),
                session_id: state.session_id.clone(),
                status,
                signal,
                acknowledgment,
            });
        }
    }

    signals.sort_by(|left, right| right.signal.created_at.cmp(&left.signal.created_at));
    Ok(signals)
}
