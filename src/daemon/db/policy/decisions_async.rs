//! Async persistence for the real enforced-decision feed.
//!
//! The synchronous gate records each enforced evaluation through the
//! `policy_graph::record_policy_decision` sink; the daemon's drain task forwards
//! those records here. Only the write path lives in this phase; the read-back
//! and reconstruction land with the replay RPC that consumes the feed.

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::{FromRow, query, query_as};

use super::super::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::policy_graph::RecordedPolicyDecision;
use crate::task_board::{PolicyAction, PolicyDecision, PolicyInput, PolicyReasonCode};

const INSERT_POLICY_DECISION_SQL: &str = "
INSERT INTO policy_decisions (
    id, recorded_at, canvas_id, revision, action, decision_tag, reason_code,
    policy_version, workflow, subject_json, evidence_json, visited_node_ids_json,
    source, enforced
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)";

const SELECT_RECENT_POLICY_DECISIONS_SQL: &str = "
SELECT id, recorded_at, canvas_id, revision, action, decision_tag, reason_code,
    policy_version, workflow, subject_json, evidence_json, visited_node_ids_json,
    source, enforced
FROM policy_decisions
ORDER BY recorded_at DESC, id DESC
LIMIT ?1";

const PRUNE_POLICY_DECISIONS_SQL: &str = "
DELETE FROM policy_decisions
WHERE id NOT IN (
    SELECT id FROM policy_decisions
    ORDER BY recorded_at DESC, id DESC
    LIMIT ?1
)";

impl AsyncDaemonDb {
    /// Persist one recorded enforced decision.
    ///
    /// # Errors
    /// Returns [`CliError`] on payload serialization or SQL failure.
    pub(crate) async fn record_policy_decision_row(
        &self,
        decision: &RecordedPolicyDecision,
    ) -> Result<(), CliError> {
        let action = enum_to_snake(&decision.input.action)?;
        let reason_code = enum_to_snake(&decision_reason_code(&decision.decision))?;
        let subject_json = serde_json::to_string(&decision.input.subject)
            .map_err(|error| db_error(format!("serialize policy decision subject: {error}")))?;
        let evidence_json = serde_json::to_string(&decision.input.evidence)
            .map_err(|error| db_error(format!("serialize policy decision evidence: {error}")))?;
        let visited_json = serde_json::to_string(&decision.visited_node_ids)
            .map_err(|error| db_error(format!("serialize policy decision nodes: {error}")))?;
        query(INSERT_POLICY_DECISION_SQL)
            .bind(&decision.id)
            .bind(&decision.recorded_at)
            .bind(decision.canvas_id.as_deref())
            .bind(i64::try_from(decision.revision).unwrap_or(i64::MAX))
            .bind(action)
            .bind(decision.decision_tag())
            .bind(reason_code)
            .bind(decision_policy_version(&decision.decision))
            .bind(decision.input.workflow.as_deref())
            .bind(subject_json)
            .bind(evidence_json)
            .bind(visited_json)
            .bind(&decision.source)
            .bind(i64::from(decision.enforced))
            .execute(self.pool())
            .await
            .map_err(|error| {
                db_error(format!("record policy decision {}: {error}", decision.id))
            })?;
        Ok(())
    }

    /// Read the most recent recorded enforced decisions, newest first.
    ///
    /// Reconstructs each [`RecordedPolicyDecision`] from its columnar row so the
    /// replay feature can re-simulate the current draft against real historical
    /// inputs.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure or when a stored payload cannot be
    /// decoded back into its domain type.
    pub(crate) async fn recent_policy_decisions(
        &self,
        limit: usize,
    ) -> Result<Vec<RecordedPolicyDecision>, CliError> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows: Vec<PolicyDecisionRow> = query_as(SELECT_RECENT_POLICY_DECISIONS_SQL)
            .bind(limit)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("read recent policy decisions: {error}")))?;
        rows.into_iter()
            .map(PolicyDecisionRow::into_record)
            .collect()
    }

    /// Delete recorded decisions beyond the newest `keep`, bounding table growth.
    ///
    /// The feed is a rolling window for replay, so only the most recent `keep`
    /// rows by recorded time are retained. Returns the number of rows removed.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failure.
    pub(crate) async fn prune_policy_decisions(&self, keep: usize) -> Result<u64, CliError> {
        let keep = i64::try_from(keep).unwrap_or(i64::MAX);
        let result = query(PRUNE_POLICY_DECISIONS_SQL)
            .bind(keep)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("prune policy decisions: {error}")))?;
        Ok(result.rows_affected())
    }
}

/// Serialize a unit-variant policy enum to its `snake_case` wire string.
fn enum_to_snake<T: Serialize>(value: &T) -> Result<String, CliError> {
    match serde_json::to_value(value) {
        Ok(Value::String(text)) => Ok(text),
        Ok(other) => Err(db_error(format!(
            "policy enum did not serialize to a string: {other}"
        ))),
        Err(error) => Err(db_error(format!("serialize policy enum: {error}"))),
    }
}

const fn decision_reason_code(decision: &PolicyDecision) -> PolicyReasonCode {
    match decision {
        PolicyDecision::Allow { reason_code, .. }
        | PolicyDecision::Deny { reason_code, .. }
        | PolicyDecision::RequireHuman { reason_code, .. }
        | PolicyDecision::RequireConsensus { reason_code, .. }
        | PolicyDecision::DryRunOnly { reason_code, .. } => *reason_code,
    }
}

fn decision_policy_version(decision: &PolicyDecision) -> &str {
    match decision {
        PolicyDecision::Allow { policy_version, .. }
        | PolicyDecision::Deny { policy_version, .. }
        | PolicyDecision::RequireHuman { policy_version, .. }
        | PolicyDecision::RequireConsensus { policy_version, .. }
        | PolicyDecision::DryRunOnly { policy_version, .. } => policy_version,
    }
}

/// One `policy_decisions` row, decoded back into its domain record.
#[derive(Debug, Clone, FromRow)]
struct PolicyDecisionRow {
    id: String,
    recorded_at: String,
    canvas_id: Option<String>,
    revision: i64,
    action: String,
    decision_tag: String,
    reason_code: String,
    policy_version: String,
    workflow: Option<String>,
    subject_json: String,
    evidence_json: String,
    visited_node_ids_json: String,
    source: String,
    enforced: bool,
}

impl PolicyDecisionRow {
    fn into_record(self) -> Result<RecordedPolicyDecision, CliError> {
        let action = snake_to_enum::<PolicyAction>(&self.action)?;
        let reason_code = snake_to_enum::<PolicyReasonCode>(&self.reason_code)?;
        let subject = serde_json::from_str(&self.subject_json)
            .map_err(|error| db_error(format!("decode policy decision subject: {error}")))?;
        let evidence = serde_json::from_str(&self.evidence_json)
            .map_err(|error| db_error(format!("decode policy decision evidence: {error}")))?;
        let visited_node_ids = serde_json::from_str(&self.visited_node_ids_json)
            .map_err(|error| db_error(format!("decode policy decision nodes: {error}")))?;
        let decision = decision_from_parts(&self.decision_tag, reason_code, self.policy_version)?;
        Ok(RecordedPolicyDecision {
            id: self.id,
            recorded_at: self.recorded_at,
            canvas_id: self.canvas_id,
            revision: u64::try_from(self.revision).unwrap_or(0),
            input: PolicyInput {
                workflow: self.workflow,
                action,
                subject,
                evidence,
            },
            decision,
            visited_node_ids,
            source: self.source,
            enforced: self.enforced,
        })
    }
}

/// Decode a unit-variant policy enum from its stored `snake_case` string.
fn snake_to_enum<T: DeserializeOwned>(text: &str) -> Result<T, CliError> {
    serde_json::from_value(Value::String(text.to_owned()))
        .map_err(|error| db_error(format!("decode policy enum '{text}': {error}")))
}

/// Rebuild a [`PolicyDecision`] from its stored tag, reason code, and version.
fn decision_from_parts(
    tag: &str,
    reason_code: PolicyReasonCode,
    policy_version: String,
) -> Result<PolicyDecision, CliError> {
    Ok(match tag {
        "allow" => PolicyDecision::Allow {
            reason_code,
            policy_version,
        },
        "deny" => PolicyDecision::Deny {
            reason_code,
            policy_version,
        },
        "require_human" => PolicyDecision::RequireHuman {
            reason_code,
            policy_version,
        },
        "require_consensus" => PolicyDecision::RequireConsensus {
            reason_code,
            policy_version,
        },
        "dry_run_only" => PolicyDecision::DryRunOnly {
            reason_code,
            policy_version,
        },
        other => return Err(db_error(format!("unknown policy decision tag '{other}'"))),
    })
}

#[cfg(test)]
mod tests {
    use tempfile::{TempDir, tempdir};

    use super::*;
    use crate::task_board::{PolicyAction, PolicyEvidence, PolicyInput, PolicySubject};

    async fn connect() -> (TempDir, AsyncDaemonDb) {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("connect async daemon db");
        (dir, db)
    }

    fn sample_record(revision: u64) -> RecordedPolicyDecision {
        let input = PolicyInput {
            workflow: Some("merge".to_owned()),
            action: PolicyAction::MergePr,
            subject: PolicySubject {
                repository: Some("octo/repo".to_owned()),
                pull_request: Some("42".to_owned()),
                ..PolicySubject::default()
            },
            evidence: PolicyEvidence {
                checks_green: Some(false),
                ..PolicyEvidence::default()
            },
        };
        let decision = PolicyDecision::Deny {
            reason_code: PolicyReasonCode::ChecksNotGreen,
            policy_version: "task-board-policy-v1".to_owned(),
        };
        RecordedPolicyDecision::new(
            revision,
            input,
            decision,
            vec!["node-1".to_owned()],
            "reviews_github",
        )
    }

    #[tokio::test]
    async fn writer_persists_discrete_columns_and_json_payloads() {
        let (_dir, db) = connect().await;
        let record = sample_record(9);
        db.record_policy_decision_row(&record)
            .await
            .expect("record");

        let (action, revision, enforced, decision_tag, reason_code, source): (
            String,
            i64,
            i64,
            String,
            String,
            String,
        ) = sqlx::query_as(
            "SELECT action, revision, enforced, decision_tag, reason_code, source \
             FROM policy_decisions",
        )
        .fetch_one(db.pool())
        .await
        .expect("read decision row");
        assert_eq!(action, "merge_pr");
        assert_eq!(revision, 9);
        assert_eq!(enforced, 1);
        assert_eq!(decision_tag, "deny");
        assert_eq!(reason_code, "checks_not_green");
        assert_eq!(source, "reviews_github");

        let (subject_json, evidence_json, visited_json): (String, String, String) = sqlx::query_as(
            "SELECT subject_json, evidence_json, visited_node_ids_json FROM policy_decisions",
        )
        .fetch_one(db.pool())
        .await
        .expect("read decision payloads");
        let subject: PolicySubject = serde_json::from_str(&subject_json).expect("subject");
        assert_eq!(subject, record.input.subject);
        let evidence: PolicyEvidence = serde_json::from_str(&evidence_json).expect("evidence");
        assert_eq!(evidence, record.input.evidence);
        let visited: Vec<String> = serde_json::from_str(&visited_json).expect("visited");
        assert_eq!(visited, vec!["node-1".to_owned()]);
    }

    #[tokio::test]
    async fn writer_appends_distinct_rows() {
        let (_dir, db) = connect().await;
        for revision in 0..3 {
            db.record_policy_decision_row(&sample_record(revision))
                .await
                .expect("record");
        }
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM policy_decisions")
            .fetch_one(db.pool())
            .await
            .expect("count");
        assert_eq!(count, 3);
    }

    #[tokio::test]
    async fn reader_round_trips_records_and_honors_limit() {
        let (_dir, db) = connect().await;
        for revision in 0..3 {
            db.record_policy_decision_row(&sample_record(revision))
                .await
                .expect("record");
        }

        let all = db.recent_policy_decisions(10).await.expect("read all");
        assert_eq!(all.len(), 3);

        let original = sample_record(0);
        let decoded = all
            .iter()
            .find(|record| record.revision == 0)
            .expect("revision 0 present");
        assert_eq!(decoded.input, original.input);
        assert_eq!(decoded.decision, original.decision);
        assert_eq!(decoded.visited_node_ids, original.visited_node_ids);
        assert_eq!(decoded.source, "reviews_github");
        assert!(decoded.enforced);

        let limited = db.recent_policy_decisions(2).await.expect("read limited");
        assert_eq!(limited.len(), 2);
    }

    #[tokio::test]
    async fn prune_keeps_only_the_newest_rows() {
        let (_dir, db) = connect().await;
        for second in 0..5 {
            let mut record = sample_record(second);
            record.id = format!("policy-decision-{second}");
            record.recorded_at = format!("2026-06-20T10:00:0{second}Z");
            db.record_policy_decision_row(&record).await.expect("record");
        }

        let removed = db.prune_policy_decisions(2).await.expect("prune");
        assert_eq!(removed, 3);

        let remaining = db.recent_policy_decisions(10).await.expect("read remaining");
        let mut survivors: Vec<String> = remaining
            .iter()
            .map(|record| record.recorded_at.clone())
            .collect();
        survivors.sort();
        assert_eq!(
            survivors,
            vec![
                "2026-06-20T10:00:03Z".to_owned(),
                "2026-06-20T10:00:04Z".to_owned(),
            ]
        );
    }

    #[tokio::test]
    async fn prune_with_a_high_keep_removes_nothing() {
        let (_dir, db) = connect().await;
        for revision in 0..3 {
            db.record_policy_decision_row(&sample_record(revision))
                .await
                .expect("record");
        }
        let removed = db.prune_policy_decisions(100).await.expect("prune");
        assert_eq!(removed, 0);
        assert_eq!(
            db.recent_policy_decisions(10).await.expect("read").len(),
            3
        );
    }
}
