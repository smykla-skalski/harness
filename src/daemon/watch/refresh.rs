use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};

use crate::daemon::db::DaemonDb;
use crate::daemon::protocol::{SessionSummary, StreamEvent};
use crate::daemon::{service, snapshot, timeline};
use crate::errors::{CliError, CliErrorKind};

use super::state::{RefreshScope, SessionDigest, WatchChanges, WatchSnapshot};

pub(super) fn refresh_watch_snapshot(
    snapshot: &mut WatchSnapshot,
    targeted_session_ids: &BTreeSet<String>,
    scope: RefreshScope,
) -> Result<WatchChanges, CliError> {
    let summaries = snapshot::session_summaries(true)?;
    let sessions_json = encode_payload(&summaries, "daemon session summaries")?;
    let current_session_ids: BTreeSet<_> = summaries
        .iter()
        .map(|summary| summary.session_id.clone())
        .collect();

    let mut changes = WatchChanges {
        sessions_updated: sessions_json != snapshot.sessions_json,
        session_ids: BTreeSet::new(),
    };
    snapshot.sessions_json = sessions_json;

    let digests_to_refresh =
        session_ids_to_refresh(snapshot, &summaries, targeted_session_ids, scope);
    for session_id in &digests_to_refresh {
        if !current_session_ids.contains(session_id) {
            if snapshot.digests.remove(session_id).is_some() {
                changes.sessions_updated = true;
                changes.session_ids.insert(session_id.clone());
            }
            continue;
        }

        let digest = load_session_digest(session_id)?;
        let previous = snapshot.digests.insert(session_id.clone(), digest.clone());
        if previous.as_ref() != Some(&digest) {
            changes.session_ids.insert(session_id.clone());
        }
    }

    prune_removed_sessions(snapshot, &current_session_ids, &mut changes);
    Ok(changes)
}

fn session_ids_to_refresh(
    snapshot: &WatchSnapshot,
    summaries: &[SessionSummary],
    targeted_session_ids: &BTreeSet<String>,
    scope: RefreshScope,
) -> BTreeSet<String> {
    if matches!(scope, RefreshScope::Full) || targeted_session_ids.is_empty() {
        return summaries
            .iter()
            .map(|summary| summary.session_id.clone())
            .chain(snapshot.digests.keys().cloned())
            .collect();
    }

    targeted_session_ids
        .iter()
        .cloned()
        .chain(
            snapshot
                .digests
                .keys()
                .filter(|session_id| targeted_session_ids.contains(*session_id))
                .cloned(),
        )
        .collect()
}

fn load_session_digest(session_id: &str) -> Result<SessionDigest, CliError> {
    let detail = snapshot::session_detail(session_id)?;
    let timeline = timeline::session_timeline(session_id)?;
    Ok(SessionDigest {
        detail_json: encode_payload(&detail, &format!("daemon session detail '{session_id}'"))?,
        timeline_json: encode_payload(&timeline, &format!("daemon timeline '{session_id}'"))?,
    })
}

fn encode_payload<T: serde::Serialize>(value: &T, label: &str) -> Result<String, CliError> {
    serde_json::to_string(value)
        .map_err(|error| CliErrorKind::workflow_io(format!("encode {label}: {error}")).into())
}

fn prune_removed_sessions(
    snapshot: &mut WatchSnapshot,
    current_session_ids: &BTreeSet<String>,
    changes: &mut WatchChanges,
) {
    let removed: Vec<_> = snapshot
        .digests
        .keys()
        .filter(|session_id| !current_session_ids.contains(*session_id))
        .cloned()
        .collect();
    for session_id in removed {
        snapshot.digests.remove(&session_id);
        changes.sessions_updated = true;
        changes.session_ids.insert(session_id);
    }
}

pub(super) fn emit_watch_changes(
    sender: &tokio::sync::broadcast::Sender<StreamEvent>,
    changes: WatchChanges,
    db: Option<&Arc<Mutex<DaemonDb>>>,
) {
    emit_watch_changes_with(
        changes,
        db,
        |db_ref| service::broadcast_sessions_updated(sender, db_ref),
        |session_id, db_ref| service::broadcast_session_updated_core(sender, session_id, db_ref),
        |session_id, db_ref| service::broadcast_session_extensions(sender, session_id, db_ref),
    );
}

pub(super) fn emit_watch_changes_with<SessionsUpdated, SessionUpdatedCore, SessionExtensions>(
    changes: WatchChanges,
    db: Option<&Arc<Mutex<DaemonDb>>>,
    mut broadcast_sessions_updated: SessionsUpdated,
    mut broadcast_session_updated_core: SessionUpdatedCore,
    mut broadcast_session_extensions: SessionExtensions,
) where
    SessionsUpdated: FnMut(Option<&DaemonDb>),
    SessionUpdatedCore: FnMut(&str, Option<&DaemonDb>),
    SessionExtensions: FnMut(&str, Option<&DaemonDb>),
{
    let db_guard = db.and_then(|db| db.lock().ok());
    let db_ref = db_guard.as_deref();
    if changes.sessions_updated {
        broadcast_sessions_updated(db_ref);
    }

    for session_id in &changes.session_ids {
        broadcast_session_updated_core(session_id, db_ref);
    }

    drop(db_guard);

    for session_id in changes.session_ids {
        broadcast_session_extensions(&session_id, None);
    }
}
