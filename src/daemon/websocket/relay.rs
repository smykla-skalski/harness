use std::sync::{Arc, Mutex};

use axum::extract::ws::Message;
use tokio::sync::{broadcast, mpsc};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{DaemonHttpState, require_async_db};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::service;
use crate::errors::CliError;

use super::broadcast::{PreparedBroadcast, ReplayBuffer, build_prepared};
use super::connection::ConnectionState;
use super::dispatch::ws_activity_log_level;

pub(crate) async fn relay_broadcast(
    mut broadcast_rx: broadcast::Receiver<Arc<PreparedBroadcast>>,
    outbound_tx: mpsc::Sender<Message>,
    connection: Arc<Mutex<ConnectionState>>,
    replay_buffer: Arc<Mutex<ReplayBuffer>>,
    state: DaemonHttpState,
) {
    while let Some(frames) =
        next_relay_frames(&mut broadcast_rx, &connection, &replay_buffer, &state).await
    {
        for frame in frames {
            if outbound_tx.send(frame).await.is_err() {
                return;
            }
        }
    }
}

pub(crate) async fn next_relay_frames(
    broadcast_rx: &mut broadcast::Receiver<Arc<PreparedBroadcast>>,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
    state: &DaemonHttpState,
) -> Option<Vec<Message>> {
    loop {
        match recv_broadcast_event(broadcast_rx, connection, replay_buffer, state).await? {
            RelayBatch::Live(prepared) => {
                if let Some(frames) = relay_prepared(&prepared, connection) {
                    return Some(frames);
                }
            }
            RelayBatch::Replay(events) => {
                let frames = relay_prepared_batch(&events, connection);
                if !frames.is_empty() {
                    return Some(frames);
                }
            }
            RelayBatch::Recovery(events) => {
                let frames = prepare_recovery_frames(events, connection, replay_buffer);
                if !frames.is_empty() {
                    return Some(frames);
                }
            }
        }
    }
}

enum RelayBatch {
    Live(Arc<PreparedBroadcast>),
    Replay(Vec<Arc<PreparedBroadcast>>),
    Recovery(Vec<StreamEvent>),
}

async fn recv_broadcast_event(
    receiver: &mut broadcast::Receiver<Arc<PreparedBroadcast>>,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
    state: &DaemonHttpState,
) -> Option<RelayBatch> {
    loop {
        let batch = match receiver.recv().await {
            Ok(prepared) => Some(RelayBatch::Live(prepared)),
            Err(broadcast::error::RecvError::Closed) => None,
            Err(broadcast::error::RecvError::Lagged(skipped)) => {
                lagged_relay_batch(skipped, connection, replay_buffer, state).await
            }
        };
        if let Some(batch) = batch {
            return Some(batch);
        }
    }
}

/// Recover from a broadcast overflow. Replay the buffered frames the connection
/// missed when the gap is still in the ring; otherwise rebuild a full snapshot
/// from the database. Replaying avoids the per-connection recovery rebuild that
/// otherwise stampedes the database when many clients lag at once.
async fn lagged_relay_batch(
    skipped: u64,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
    state: &DaemonHttpState,
) -> Option<RelayBatch> {
    let last_relayed_seq = connection.lock().expect("connection lock").last_relayed_seq;
    let replay = replay_buffer
        .lock()
        .expect("replay buffer lock")
        .replay_since(last_relayed_seq);
    if let Some(replay) = replay
        && !replay.is_empty()
    {
        warn_lagged_replay(skipped, replay.len());
        return Some(RelayBatch::Replay(replay));
    }

    let events: Vec<StreamEvent> = recovery_events_for_connection(connection, state).await;
    warn_lagged_recovery(skipped, events.len());
    (!events.is_empty()).then_some(RelayBatch::Recovery(events))
}

#[derive(Clone, Debug, Default)]
struct RelayRecoveryPlan {
    include_sessions_updated: bool,
    session_ids: Vec<String>,
}

impl RelayRecoveryPlan {
    fn is_empty(&self) -> bool {
        !self.include_sessions_updated && self.session_ids.is_empty()
    }
}

fn recovery_plan_for_connection(connection: &Arc<Mutex<ConnectionState>>) -> RelayRecoveryPlan {
    let state = connection.lock().expect("connection lock");
    let mut session_ids: Vec<_> = state.session_subscriptions.iter().cloned().collect();
    session_ids.sort();
    RelayRecoveryPlan {
        include_sessions_updated: state.global_subscription,
        session_ids,
    }
}

async fn recovery_events_for_connection(
    connection: &Arc<Mutex<ConnectionState>>,
    state: &DaemonHttpState,
) -> Vec<StreamEvent> {
    let plan = recovery_plan_for_connection(connection);
    if plan.is_empty() {
        return Vec::new();
    }

    match require_async_db(state, "websocket recovery snapshot") {
        Ok(async_db) => build_recovery_events_async(&plan, state, async_db).await,
        Err(error) => recovery_events_on_error(&error),
    }
}

fn recovery_events_on_error(error: &CliError) -> Vec<StreamEvent> {
    warn_recovery_snapshot_failure(error);
    Vec::new()
}

async fn build_recovery_events_async(
    plan: &RelayRecoveryPlan,
    state: &DaemonHttpState,
    async_db: &AsyncDaemonDb,
) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    if plan.include_sessions_updated {
        append_recovery_event(
            &mut events,
            cached_sessions_updated_event(state, async_db).await,
            "sessions_updated",
            None,
        );
    }
    for session_id in &plan.session_ids {
        append_recovery_event(
            &mut events,
            service::session_updated_core_event_async(session_id, Some(async_db)).await,
            "session_updated",
            Some(session_id),
        );
    }
    events
}

/// Build (or reuse) the global `sessions_updated` recovery snapshot behind a
/// single-flight lock. The change generation is read outside the lock so a herd
/// of relays lagging at the same instant read it in parallel; only the cache
/// check and the rebuild are serialized, collapsing the herd into one build per
/// change generation instead of one rebuild per connection.
///
/// A cached snapshot always reflects data at least as new as its key (the key is
/// read before the build), so reuse is never stale even when a mutation lands
/// mid-storm; that case simply misses the cache and rebuilds. If the generation
/// cannot be read the cache is bypassed entirely, so a degraded database can
/// never pin a stale snapshot under key zero.
async fn cached_sessions_updated_event(
    state: &DaemonHttpState,
    async_db: &AsyncDaemonDb,
) -> Result<StreamEvent, CliError> {
    let Ok(current) = async_db.current_change_sequence().await else {
        return service::sessions_updated_event_async(Some(async_db)).await;
    };
    let mut cache = state.recovery_snapshot.lock().await;
    if let Some(event) = cache.get_fresh(current) {
        return Ok(event);
    }
    let event = service::sessions_updated_event_async(Some(async_db)).await?;
    cache.store(current, event.clone());
    Ok(event)
}

fn append_recovery_event(
    events: &mut Vec<StreamEvent>,
    event: Result<StreamEvent, CliError>,
    event_name: &str,
    session_id: Option<&str>,
) {
    match event {
        Ok(event) => events.push(event),
        Err(error) => warn_recovery_event_failure(&error, event_name, session_id),
    }
}

fn prepare_recovery_frames(
    events: Vec<StreamEvent>,
    connection: &Arc<Mutex<ConnectionState>>,
    replay_buffer: &Arc<Mutex<ReplayBuffer>>,
) -> Vec<Message> {
    let mut frames = Vec::new();
    for event in events {
        let prepared = build_prepared(event, replay_buffer);
        if let Some(event_frames) = relay_prepared(&prepared, connection) {
            frames.extend(event_frames);
        }
    }
    frames
}

fn relay_prepared_batch(
    events: &[Arc<PreparedBroadcast>],
    connection: &Arc<Mutex<ConnectionState>>,
) -> Vec<Message> {
    let mut frames = Vec::new();
    for prepared in events {
        if let Some(event_frames) = relay_prepared(prepared, connection) {
            frames.extend(event_frames);
        }
    }
    frames
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn relay_prepared(
    prepared: &PreparedBroadcast,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<Vec<Message>> {
    {
        let mut state = connection.lock().expect("connection lock");
        if !state.should_relay_session(prepared.session_id.as_deref()) {
            return None;
        }
        state.last_relayed_seq = state.last_relayed_seq.max(prepared.seq);
    }

    tracing::event!(
        ws_activity_log_level(),
        event = %prepared.event_name,
        session_id = prepared.session_id.as_deref().unwrap_or("-"),
        seq = prepared.seq,
        frame_count = prepared.ws_frames.len(),
        "ws push"
    );
    Some(prepared.ws_frames.clone())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_lagged_replay(skipped: u64, replayed_events: usize) {
    tracing::warn!(
        skipped,
        replayed_events,
        "websocket relay lagged; replaying from buffer"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_lagged_recovery(skipped: u64, recovery_events: usize) {
    tracing::warn!(
        skipped,
        recovery_events,
        "websocket relay lagged; sending recovery snapshot"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_recovery_snapshot_failure(error: &CliError) {
    tracing::warn!(%error, "failed to build websocket recovery snapshot");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_recovery_event_failure(error: &CliError, event_name: &str, session_id: Option<&str>) {
    tracing::warn!(
        %error,
        event = event_name,
        session_id = session_id.unwrap_or("-"),
        "failed to build websocket recovery event"
    );
}

#[cfg(test)]
mod tests {
    use super::super::test_support::test_http_state_with_async_db_timeline;
    use super::*;

    #[tokio::test]
    async fn recovery_events_use_async_db_when_sync_db_is_unavailable() {
        let state = test_http_state_with_async_db_timeline().await;
        let connection = Arc::new(Mutex::new(ConnectionState::new()));
        {
            let mut connection_state = connection.lock().expect("connection lock");
            connection_state.global_subscription = true;
            connection_state
                .session_subscriptions
                .insert("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into());
        }

        let events = recovery_events_for_connection(&connection, &state).await;

        assert!(
            events.iter().any(|event| event.event == "sessions_updated"),
            "expected sessions_updated recovery event"
        );
        assert!(
            events.iter().any(|event| {
                event.event == "session_updated"
                    && event.session_id.as_deref() == Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4")
            }),
            "expected session_updated recovery event"
        );
    }
}
