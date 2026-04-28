//! Fold-flush batching for ACP notifications supplied by the SDK dispatcher.

use std::sync::Arc;

use agent_client_protocol::schema::SessionNotification;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::timeout;

use super::connection::{ConnectionConfig, EventBatch};
use super::events::materialise_batch;
use super::ring::{RingConfig, SessionRing};
use super::supervision::AcpSessionSupervisor;

/// Handle for a notification batcher task.
pub struct NotificationBatcherHandle {
    pub notifications: mpsc::Sender<SessionNotification>,
    pub events: mpsc::Receiver<EventBatch>,
    pub task: JoinHandle<()>,
}

/// Spawn a fold-flush batcher fed by SDK notification callbacks.
#[must_use]
pub fn spawn_notification_batcher(
    agent_name: String,
    session_id: String,
    supervisor: Arc<AcpSessionSupervisor>,
    config: ConnectionConfig,
) -> NotificationBatcherHandle {
    let (notification_tx, notification_rx) = mpsc::channel(config.channel_buffer);
    let (event_tx, event_rx) = mpsc::channel(config.channel_buffer);
    let task = tokio::spawn(notification_batch_loop(
        notification_rx,
        event_tx,
        agent_name,
        session_id,
        supervisor,
        config.ring,
    ));
    NotificationBatcherHandle {
        notifications: notification_tx,
        events: event_rx,
        task,
    }
}

async fn notification_batch_loop(
    mut notification_rx: mpsc::Receiver<SessionNotification>,
    event_tx: mpsc::Sender<EventBatch>,
    agent_name: String,
    session_id: String,
    supervisor: Arc<AcpSessionSupervisor>,
    ring_config: RingConfig,
) {
    let mut ring = SessionRing::new(ring_config);
    let mut sequence = 0;

    loop {
        let flush_timeout = ring
            .elapsed()
            .and_then(|elapsed| ring.config().max_duration.checked_sub(elapsed))
            .unwrap_or(ring.config().max_duration);

        match timeout(flush_timeout, notification_rx.recv()).await {
            Ok(Some(notification)) => {
                push_notification(
                    notification,
                    &supervisor,
                    &mut ring,
                    &event_tx,
                    &agent_name,
                    &session_id,
                    &mut sequence,
                )
                .await;
            }
            Ok(None) => break,
            Err(_) => {
                flush_ring(
                    &mut ring,
                    &event_tx,
                    &agent_name,
                    &session_id,
                    &mut sequence,
                )
                .await;
            }
        }
    }

    if !ring.is_empty() {
        flush_ring(
            &mut ring,
            &event_tx,
            &agent_name,
            &session_id,
            &mut sequence,
        )
        .await;
    }
}

async fn flush_ring(
    ring: &mut SessionRing,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) {
    let Some(batch) = next_event_batch(ring, agent_name, session_id, sequence) else {
        return;
    };
    let _ = tx.send(batch).await;
}

async fn push_notification(
    notification: SessionNotification,
    supervisor: &AcpSessionSupervisor,
    ring: &mut SessionRing,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) {
    supervisor.record_event();
    if ring.push(notification) {
        flush_ring(ring, tx, agent_name, session_id, sequence).await;
    }
}

fn next_event_batch(
    ring: &mut SessionRing,
    agent_name: &str,
    session_id: &str,
    sequence: &mut u64,
) -> Option<EventBatch> {
    let raw_count = ring.len();
    if raw_count == 0 {
        return None;
    }
    let (events, next_sequence) =
        materialise_batch(ring.updates(), agent_name, session_id, *sequence);
    *sequence = next_sequence;
    ring.clear();
    Some(EventBatch { events, raw_count })
}
