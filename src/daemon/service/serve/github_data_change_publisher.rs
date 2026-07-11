use tokio::sync::{broadcast, watch};
use tokio::task::JoinHandle;
use tokio::time::{Duration, sleep};

use crate::daemon::protocol::StreamEvent;
use crate::github_api::{GitHubDataChange, GitHubProtectedClient};
use crate::workspace::utc_now;

const EVENT_NAME: &str = "github_data_changed";

pub(super) fn spawn_github_data_change_publisher(
    sender: broadcast::Sender<StreamEvent>,
    mut shutdown_rx: watch::Receiver<bool>,
) -> JoinHandle<()> {
    let mut changes = GitHubProtectedClient::data_changes();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                shutdown_changed = shutdown_rx.changed() => {
                    if shutdown_changed.is_err() || *shutdown_rx.borrow() {
                        return;
                    }
                }
                received = changes.recv() => {
                    match received {
                        Ok(change) => {
                            let change = coalesce_changes(&mut changes, change).await;
                            broadcast_github_data_change(&sender, &change);
                        }
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            tracing::warn!(skipped, "github data change publisher lagged");
                            broadcast_github_data_change(
                                &sender,
                                &GitHubDataChange {
                                    revision: GitHubProtectedClient::data_revision(),
                                    operation: "github.data_change_recovery".to_string(),
                                },
                            );
                        }
                        Err(broadcast::error::RecvError::Closed) => return,
                    }
                }
            }
        }
    })
}

async fn coalesce_changes(
    changes: &mut broadcast::Receiver<GitHubDataChange>,
    mut latest: GitHubDataChange,
) -> GitHubDataChange {
    sleep(Duration::from_millis(100)).await;
    while let Ok(change) = changes.try_recv() {
        if change.revision >= latest.revision {
            latest = change;
        }
    }
    latest
}

pub(crate) fn broadcast_github_data_change(
    sender: &broadcast::Sender<StreamEvent>,
    change: &GitHubDataChange,
) {
    let Some(event) = stream_event_for_change(change) else {
        return;
    };
    let _ = sender.send(event);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "the push boundary logs serialization failure before dropping an unencodable event"
)]
fn stream_event_for_change(change: &GitHubDataChange) -> Option<StreamEvent> {
    let payload = match serde_json::to_value(change) {
        Ok(payload) => payload,
        Err(error) => {
            tracing::warn!(%error, "serialize github data change push payload");
            return None;
        }
    };
    Some(StreamEvent {
        event: EVENT_NAME.to_string(),
        recorded_at: utc_now(),
        session_id: None,
        payload,
    })
}

#[cfg(test)]
mod tests {
    use tokio::sync::broadcast;

    use super::{GitHubDataChange, broadcast_github_data_change, coalesce_changes};
    use crate::daemon::protocol::StreamEvent;

    #[test]
    fn publishes_global_github_data_change() {
        let (sender, mut receiver) = broadcast::channel::<StreamEvent>(2);

        broadcast_github_data_change(
            &sender,
            &GitHubDataChange {
                revision: 7,
                operation: "reviews.merge".to_string(),
            },
        );

        let event = receiver.try_recv().expect("github data change event");
        assert_eq!(event.event, "github_data_changed");
        assert_eq!(event.session_id, None);
        assert_eq!(event.payload["revision"], 7);
        assert_eq!(event.payload["operation"], "reviews.merge");
    }

    #[tokio::test]
    async fn same_revision_local_ready_event_replaces_early_mutation_event() {
        let (sender, mut receiver) = broadcast::channel(2);
        sender
            .send(GitHubDataChange {
                revision: 7,
                operation: "task_board.github.issue_update".to_string(),
            })
            .expect("first change");
        let first = receiver.recv().await.expect("first receive");
        sender
            .send(GitHubDataChange {
                revision: 7,
                operation: "task_board.github.local_sync_ready".to_string(),
            })
            .expect("ready change");

        let coalesced = coalesce_changes(&mut receiver, first).await;

        assert_eq!(coalesced.revision, 7);
        assert_eq!(coalesced.operation, "task_board.github.local_sync_ready");
    }
}
