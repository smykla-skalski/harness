use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::persistence::versioned_json::VersionedJsonRepository;

use super::models::PolicyWorkflowEvent;

pub const POLICY_EVENT_INBOX_SCHEMA_VERSION: u32 = 1;

/// Pending events older than this are pruned on publish and on drain so an
/// event that never matches a waiting run cannot accumulate forever.
const EVENT_RETENTION_SECONDS: i64 = 3600;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyEventInboxDocument {
    pub schema_version: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub events: Vec<PolicyWorkflowEvent>,
}

impl Default for PolicyEventInboxDocument {
    fn default() -> Self {
        Self {
            schema_version: POLICY_EVENT_INBOX_SCHEMA_VERSION,
            events: Vec::new(),
        }
    }
}

/// A durable, domain-agnostic queue of wake-up events. Any producer can
/// `publish` an event keyed by `(event_key, subject_key)`; a background
/// drainer reads `pending` events, resumes the matching waiting runs, then
/// calls `remove_delivered`. Delivery is decoupled from the producer so a
/// run resumes even when the producing refresh and the consuming loop run on
/// different schedules.
pub struct PolicyEventInbox {
    repository: VersionedJsonRepository<PolicyEventInboxDocument>,
}

impl PolicyEventInbox {
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self {
            repository: VersionedJsonRepository::new(
                root.join("policy-event-inbox-v1.json"),
                POLICY_EVENT_INBOX_SCHEMA_VERSION,
            ),
        }
    }

    /// Durably enqueue an event, deduped by `(event_key, subject_key)` so the
    /// same pending wake-up is stored once; a re-publish refreshes its
    /// `occurred_at`.
    pub fn publish(&self, event: PolicyWorkflowEvent) -> Result<(), CliError> {
        self.publish_at(event, Utc::now())
    }

    pub(crate) fn publish_at(
        &self,
        event: PolicyWorkflowEvent,
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            prune_expired(&mut document.events, now);
            document
                .events
                .retain(|existing| !same_slot(existing, &event));
            document.events.push(event.clone());
            Ok(Some(document))
        })?;
        Ok(())
    }

    /// All currently pending events, oldest first by insertion order.
    pub fn pending(&self) -> Result<Vec<PolicyWorkflowEvent>, CliError> {
        Ok(self.repository.load()?.unwrap_or_default().events)
    }

    /// Remove the supplied delivered events and prune any expired leftovers.
    pub fn remove_delivered(&self, delivered: &[PolicyWorkflowEvent]) -> Result<(), CliError> {
        self.remove_delivered_at(delivered, Utc::now())
    }

    pub(crate) fn remove_delivered_at(
        &self,
        delivered: &[PolicyWorkflowEvent],
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        if delivered.is_empty() {
            return self.prune(now);
        }
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            document
                .events
                .retain(|event| !delivered.iter().any(|removed| removed == event));
            prune_expired(&mut document.events, now);
            Ok(Some(document))
        })?;
        Ok(())
    }

    fn prune(&self, now: DateTime<Utc>) -> Result<(), CliError> {
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            prune_expired(&mut document.events, now);
            Ok(Some(document))
        })?;
        Ok(())
    }
}

fn same_slot(left: &PolicyWorkflowEvent, right: &PolicyWorkflowEvent) -> bool {
    left.event_key == right.event_key && left.subject_key == right.subject_key
}

fn prune_expired(events: &mut Vec<PolicyWorkflowEvent>, now: DateTime<Utc>) {
    events.retain(|event| !event_is_expired(event, now));
}

fn event_is_expired(event: &PolicyWorkflowEvent, now: DateTime<Utc>) -> bool {
    DateTime::parse_from_rfc3339(&event.occurred_at).is_ok_and(|occurred| {
        now.signed_duration_since(occurred.with_timezone(&Utc))
            .num_seconds()
            > EVENT_RETENTION_SECONDS
    })
}

#[cfg(test)]
#[path = "inbox_tests.rs"]
mod inbox_tests;
