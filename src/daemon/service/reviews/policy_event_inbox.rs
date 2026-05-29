use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Duration;

use tokio::task::JoinHandle;
use tokio::time::interval as tokio_interval;

use crate::errors::CliError;
use crate::reviews::policy::{ReviewsPolicyActionExecutor, REVIEWS_CHECKS_PASSED_EVENT};
use crate::reviews::{ReviewCheckStatus, ReviewItem, ReviewsPolicyRunResponse};
use crate::task_board::policy_runtime::inbox::PolicyEventInbox;
use crate::task_board::policy_runtime::models::PolicyWorkflowEvent;
use crate::task_board::store::default_board_root;

use super::policy::{resume_reviews_policy_event, resume_reviews_policy_event_with_executor};

/// Derive `reviews.checks_passed` wake-ups from a fresh reviews snapshot,
/// durably enqueue them, and immediately attempt an inline resume so an open
/// dashboard stays responsive. The durable enqueue means a background drain
/// loop still resumes the run when the inline attempt races a concurrent claim
/// or its token is momentarily unavailable.
pub(crate) async fn resume_waiting_reviews_policy_runs(items: &[ReviewItem]) {
    resume_waiting_reviews_policy_runs_in(default_board_root(), items).await;
}

async fn resume_waiting_reviews_policy_runs_in(root: PathBuf, items: &[ReviewItem]) {
    let inbox = PolicyEventInbox::new(root);
    let subject_keys = items
        .iter()
        .filter(|item| item.check_status == ReviewCheckStatus::Success)
        .map(ReviewItem::target)
        .map(|target| target.subject_key())
        .collect::<BTreeSet<_>>();
    for subject_key in subject_keys {
        let event = PolicyWorkflowEvent::named(REVIEWS_CHECKS_PASSED_EVENT, &subject_key);
        if let Err(error) = inbox.publish(event.clone()) {
            tracing::warn!(
                event_key = %event.event_key,
                subject_key = %event.subject_key,
                error = %error,
                "failed to enqueue reviews policy event"
            );
        }
        if let Err(error) = resume_reviews_policy_event(&event).await {
            tracing::warn!(
                event_key = %event.event_key,
                subject_key = %event.subject_key,
                error = %error,
                "failed to resume waiting reviews policy runs"
            );
        }
    }
}

/// Drain the durable event inbox: resume every waiting run matched by a pending
/// event, then remove the delivered events. Domain-agnostic in storage; reviews
/// is the first event producer and consumer.
pub async fn resume_due_reviews_policy_events() -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let root = default_board_root();
    let inbox = PolicyEventInbox::new(root);
    let pending = inbox.pending()?;
    if pending.is_empty() {
        return Ok(Vec::new());
    }
    let mut resumed_runs = Vec::new();
    let mut delivered = Vec::new();
    for event in pending {
        match resume_reviews_policy_event(&event).await {
            Ok(mut resumed) => {
                resumed_runs.append(&mut resumed);
                delivered.push(event);
            }
            Err(error) => {
                tracing::warn!(
                    event_key = %event.event_key,
                    subject_key = %event.subject_key,
                    error = %error,
                    "failed to drain reviews policy event"
                );
            }
        }
    }
    inbox.remove_delivered(&delivered)?;
    Ok(resumed_runs)
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) async fn resume_due_reviews_policy_events_with_executor_at<E>(
    root: PathBuf,
    executor: E,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Clone + Send + Sync + 'static,
{
    let inbox = PolicyEventInbox::new(root.clone());
    let pending = inbox.pending()?;
    let mut resumed_runs = Vec::new();
    let mut delivered = Vec::new();
    for event in pending {
        let mut resumed =
            resume_reviews_policy_event_with_executor(root.clone(), executor.clone(), &event)
                .await?;
        resumed_runs.append(&mut resumed);
        delivered.push(event);
    }
    inbox.remove_delivered(&delivered)?;
    Ok(resumed_runs)
}

/// Periodically drain the event inbox on the daemon poll cadence so waiting
/// runs resume even when no reviews refresh is happening.
pub(crate) fn spawn_reviews_policy_event_loop(interval: Duration) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio_interval(interval);
        loop {
            ticker.tick().await;
            match resume_due_reviews_policy_events().await {
                Ok(resumed_runs) => {
                    if !resumed_runs.is_empty() {
                        tracing::info!(
                            resumed_run_count = resumed_runs.len(),
                            "drained reviews policy event inbox"
                        );
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "failed to drain reviews policy event inbox");
                }
            }
        }
    })
}

#[cfg(test)]
#[path = "policy_event_inbox_tests.rs"]
mod policy_event_inbox_tests;
