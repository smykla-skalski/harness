#[cfg(test)]
use std::path::PathBuf;

#[cfg(test)]
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[cfg(test)]
use crate::errors::CliError;
#[cfg(test)]
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::workspace::utc_now;

pub const POLICY_HANDOFF_OUTBOX_SCHEMA_VERSION: u32 = 1;

/// Records older than this are pruned on append so a handoff trail that never
/// gets consumed downstream cannot accumulate forever. Mirrors the event
/// inbox retention so both durable surfaces age out at the same rate.
#[cfg(test)]
const HANDOFF_RETENTION_SECONDS: i64 = 3600;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandoffRecord {
    pub handoff_key: String,
    pub workflow_id: String,
    pub subject_key: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyHandoffOutboxDocument {
    pub schema_version: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub records: Vec<HandoffRecord>,
}

impl Default for PolicyHandoffOutboxDocument {
    fn default() -> Self {
        Self {
            schema_version: POLICY_HANDOFF_OUTBOX_SCHEMA_VERSION,
            records: Vec::new(),
        }
    }
}

/// A durable, append-only trail of workflow handoffs. The handoff provider
/// records each emitted handoff here so the side effect survives a daemon
/// restart and downstream tooling can audit what was handed off to whom.
#[cfg(test)]
pub struct PolicyHandoffOutbox {
    repository: VersionedJsonRepository<PolicyHandoffOutboxDocument>,
}

#[cfg(test)]
impl PolicyHandoffOutbox {
    #[must_use]
    pub fn new(mut root: PathBuf) -> Self {
        root.push("policy-handoff-outbox-v1.json");
        Self {
            repository: VersionedJsonRepository::new(root, POLICY_HANDOFF_OUTBOX_SCHEMA_VERSION),
        }
    }

    /// Durably append a handoff record, pruning any expired leftovers first.
    ///
    /// # Errors
    /// Returns `CliError` if the durable outbox file cannot be read, parsed, or
    /// rewritten while appending the record.
    pub fn record(&self, record: HandoffRecord) -> Result<(), CliError> {
        self.record_at(record, Utc::now())
    }

    pub(crate) fn record_at(
        &self,
        record: HandoffRecord,
        now: DateTime<Utc>,
    ) -> Result<(), CliError> {
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            prune_expired(&mut document.records, now);
            document.records.push(record);
            Ok(Some(document))
        })?;
        Ok(())
    }

    /// All currently retained records, oldest first by insertion order.
    ///
    /// # Errors
    /// Returns `CliError` if the durable outbox file cannot be read or parsed.
    pub fn records(&self) -> Result<Vec<HandoffRecord>, CliError> {
        Ok(self.repository.load()?.unwrap_or_default().records)
    }
}

#[must_use]
pub fn handoff_record(handoff_key: &str, workflow_id: &str, subject_key: &str) -> HandoffRecord {
    HandoffRecord {
        handoff_key: handoff_key.to_owned(),
        workflow_id: workflow_id.to_owned(),
        subject_key: subject_key.to_owned(),
        recorded_at: utc_now(),
    }
}

#[cfg(test)]
fn prune_expired(records: &mut Vec<HandoffRecord>, now: DateTime<Utc>) {
    records.retain(|record| !record_is_expired(&record.recorded_at, now));
}

#[cfg(test)]
fn record_is_expired(recorded_at: &str, now: DateTime<Utc>) -> bool {
    DateTime::parse_from_rfc3339(recorded_at).is_ok_and(|recorded| {
        now.signed_duration_since(recorded.with_timezone(&Utc))
            .num_seconds()
            > HANDOFF_RETENTION_SECONDS
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn at(rfc3339: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(rfc3339)
            .expect("parse fixed instant")
            .with_timezone(&Utc)
    }

    #[test]
    fn record_then_records_round_trips_through_the_durable_file() {
        let dir = tempdir().expect("tempdir");
        let outbox = PolicyHandoffOutbox::new(dir.path().to_path_buf());
        outbox
            .record(handoff_record(
                "next-handler",
                "reviews_auto",
                "owner/repo#1",
            ))
            .expect("record handoff");

        let reopened = PolicyHandoffOutbox::new(dir.path().to_path_buf());
        let records = reopened.records().expect("records");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].handoff_key, "next-handler");
        assert_eq!(records[0].workflow_id, "reviews_auto");
        assert_eq!(records[0].subject_key, "owner/repo#1");
    }

    #[test]
    fn record_prunes_entries_older_than_retention() {
        let dir = tempdir().expect("tempdir");
        let outbox = PolicyHandoffOutbox::new(dir.path().to_path_buf());
        outbox
            .record_at(
                HandoffRecord {
                    handoff_key: "stale".to_owned(),
                    workflow_id: "reviews_auto".to_owned(),
                    subject_key: "owner/repo#9".to_owned(),
                    recorded_at: "2026-05-29T10:00:00Z".to_owned(),
                },
                at("2026-05-29T10:00:00Z"),
            )
            .expect("record stale");
        outbox
            .record_at(
                HandoffRecord {
                    handoff_key: "fresh".to_owned(),
                    workflow_id: "reviews_auto".to_owned(),
                    subject_key: "owner/repo#1".to_owned(),
                    recorded_at: "2026-05-29T12:00:00Z".to_owned(),
                },
                at("2026-05-29T12:00:00Z"),
            )
            .expect("record fresh");
        let records = outbox.records().expect("records");
        assert_eq!(records.len(), 1, "stale record pruned by retention");
        assert_eq!(records[0].handoff_key, "fresh");
    }
}
