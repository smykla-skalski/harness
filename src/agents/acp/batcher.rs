//! Fold-flush batching for ACP notifications supplied by the SDK dispatcher.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

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
    pub notifications: mpsc::Sender<RoutedSessionNotification>,
    pub events: mpsc::Receiver<EventBatch>,
    pub task: JoinHandle<()>,
}

#[derive(Debug)]
pub struct RoutedSessionNotification {
    pub acp_id: String,
    pub session_id: String,
    pub notification: SessionNotification,
}

struct SessionBatchState {
    acp_id: String,
    ring: SessionRing,
    sequence: u64,
}

/// Spawn a fold-flush batcher fed by SDK notification callbacks.
#[must_use]
pub fn spawn_notification_batcher(
    agent_name: String,
    supervisor: Arc<AcpSessionSupervisor>,
    config: ConnectionConfig,
) -> NotificationBatcherHandle {
    let (notification_tx, notification_rx) = mpsc::channel(config.channel_buffer);
    let (event_tx, event_rx) = mpsc::channel(config.channel_buffer);
    let task = tokio::spawn(notification_batch_loop(
        notification_rx,
        event_tx,
        agent_name,
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
    mut notification_rx: mpsc::Receiver<RoutedSessionNotification>,
    event_tx: mpsc::Sender<EventBatch>,
    agent_name: String,
    supervisor: Arc<AcpSessionSupervisor>,
    ring_config: RingConfig,
) {
    let mut sessions = BTreeMap::<String, SessionBatchState>::new();

    loop {
        let flush_timeout = next_flush_timeout(&sessions, &ring_config);

        match timeout(flush_timeout, notification_rx.recv()).await {
            Ok(Some(routed)) => {
                push_notification(
                    routed,
                    &supervisor,
                    &mut sessions,
                    &event_tx,
                    &agent_name,
                    &ring_config,
                )
                .await;
            }
            Ok(None) => break,
            Err(_) => flush_all(&mut sessions, &event_tx, &agent_name).await,
        }
    }

    flush_all(&mut sessions, &event_tx, &agent_name).await;
}

fn next_flush_timeout(
    sessions: &BTreeMap<String, SessionBatchState>,
    ring_config: &RingConfig,
) -> Duration {
    sessions
        .values()
        .filter(|state| !state.ring.is_empty())
        .filter_map(|state| {
            state
                .ring
                .elapsed()
                .map(|elapsed| ring_config.max_duration.saturating_sub(elapsed))
        })
        .min()
        .unwrap_or(ring_config.max_duration)
}

async fn flush_all(
    sessions: &mut BTreeMap<String, SessionBatchState>,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
) {
    let keys = sessions.keys().cloned().collect::<Vec<_>>();
    for key in keys {
        if let Some(state) = sessions.get_mut(&key) {
            flush_ring(&key, state, tx, agent_name).await;
        }
    }
}

async fn flush_ring(
    session_id: &str,
    state: &mut SessionBatchState,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
) {
    let Some(batch) = next_event_batch(session_id, state, agent_name) else {
        return;
    };
    let _ = tx.send(batch).await;
}

async fn push_notification(
    routed: RoutedSessionNotification,
    supervisor: &AcpSessionSupervisor,
    sessions: &mut BTreeMap<String, SessionBatchState>,
    tx: &mpsc::Sender<EventBatch>,
    agent_name: &str,
    ring_config: &RingConfig,
) {
    supervisor.record_event();
    let session_id = routed.session_id;
    let state = sessions
        .entry(session_id.clone())
        .or_insert_with(|| SessionBatchState {
            acp_id: routed.acp_id.clone(),
            ring: SessionRing::new(ring_config.clone()),
            sequence: 0,
        });
    if state.ring.push(routed.notification) {
        flush_ring(&session_id, state, tx, agent_name).await;
    }
}

fn next_event_batch(
    session_id: &str,
    state: &mut SessionBatchState,
    agent_name: &str,
) -> Option<EventBatch> {
    let raw_count = state.ring.len();
    if raw_count == 0 {
        return None;
    }
    let (events, next_sequence) =
        materialise_batch(state.ring.updates(), agent_name, session_id, state.sequence);
    state.sequence = next_sequence;
    state.ring.clear();
    Some(EventBatch {
        acp_id: state.acp_id.clone(),
        session_id: session_id.to_string(),
        events,
        raw_count,
    })
}

#[cfg(test)]
mod tests {
    use std::process::Command;
    use std::sync::Arc;
    use std::time::Duration;

    use agent_client_protocol::schema::{
        ContentBlock, ContentChunk, SessionId, SessionNotification, SessionUpdate, TextContent,
    };

    use crate::agents::runtime::event::ConversationEventKind;

    use super::*;

    #[tokio::test]
    #[cfg(unix)]
    async fn routes_interleaved_notifications_to_separate_logical_batches() {
        let mut child = Command::new("sleep")
            .arg("60")
            .spawn()
            .expect("spawn child");
        let supervisor = Arc::new(AcpSessionSupervisor::new(&child, Default::default()));
        let handle = spawn_notification_batcher(
            "agent".to_string(),
            supervisor,
            ConnectionConfig {
                ring: RingConfig {
                    max_updates: 2,
                    max_bytes: 64 * 1024,
                    max_duration: Duration::from_secs(1),
                },
                channel_buffer: 4,
            },
        );
        let mut events = handle.events;
        handle
            .notifications
            .send(routed("acp-1", "sess-1", "acp-session-1", "one"))
            .await
            .expect("send first notification");
        handle
            .notifications
            .send(routed("acp-2", "sess-2", "acp-session-2", "two"))
            .await
            .expect("send second notification");
        handle
            .notifications
            .send(routed("acp-1", "sess-1", "acp-session-1", "three"))
            .await
            .expect("send third notification");
        handle
            .notifications
            .send(routed("acp-2", "sess-2", "acp-session-2", "four"))
            .await
            .expect("send fourth notification");

        let first = events.recv().await.expect("first batch");
        let second = events.recv().await.expect("second batch");
        assert_eq!(
            (first.acp_id.as_str(), first.session_id.as_str()),
            ("acp-1", "sess-1")
        );
        assert_eq!(
            (second.acp_id.as_str(), second.session_id.as_str()),
            ("acp-2", "sess-2")
        );
        assert_eq!(first.raw_count, 2);
        assert_eq!(second.raw_count, 2);
        assert_eq!(first.events.len(), 2);
        assert_eq!(second.events.len(), 2);
        assert_text_events(&first, &["one", "three"]);
        assert_text_events(&second, &["two", "four"]);

        handle.task.abort();
        let _ = child.kill();
        let _ = child.wait();
    }

    fn assert_text_events(batch: &EventBatch, expected: &[&str]) {
        let actual = batch
            .events
            .iter()
            .map(|event| match &event.kind {
                ConversationEventKind::AssistantText { content } => content.as_str(),
                other => panic!("expected assistant text, got {other:?}"),
            })
            .collect::<Vec<_>>();
        assert_eq!(actual, expected);
    }

    fn routed(
        acp_id: &str,
        session_id: &str,
        acp_session_id: &str,
        text: &str,
    ) -> RoutedSessionNotification {
        RoutedSessionNotification {
            acp_id: acp_id.to_string(),
            session_id: session_id.to_string(),
            notification: SessionNotification::new(
                SessionId::new(acp_session_id),
                SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                    TextContent::new(text),
                ))),
            ),
        }
    }
}
