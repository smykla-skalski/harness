//! Async persistence for the real enforced-decision feed.
//!
//! The synchronous gate records each enforced evaluation through the
//! `policy_graph::record_policy_decision` sink; the daemon's drain task forwards
//! those records here. Only the write path lives in this phase; the read-back
//! and reconstruction land with the replay RPC that consumes the feed.

use serde::Serialize;
use serde_json::Value;
use sqlx::query;

use super::super::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::policy_graph::RecordedPolicyDecision;
use crate::task_board::{PolicyDecision, PolicyReasonCode};

const INSERT_POLICY_DECISION_SQL: &str = "
INSERT INTO policy_decisions (
    id, recorded_at, canvas_id, revision, action, decision_tag, reason_code,
    policy_version, workflow, subject_json, evidence_json, visited_node_ids_json,
    source, enforced
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)";

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
}
