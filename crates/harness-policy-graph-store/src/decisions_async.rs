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

use crate::{PolicyGraphStore, db_error};
use harness_kernel::errors::CliError;
use harness_task_board::policy_graph::RecordedPolicyDecision;
use harness_task_board::{PolicyAction, PolicyDecision, PolicyInput, PolicyReasonCode};

const INSERT_POLICY_DECISION_SQL: &str = "
INSERT INTO policy_decisions (
    id, recorded_at, canvas_id, revision, action, decision_tag, reason_code,
    policy_version, workflow, subject_json, evidence_json, visited_node_ids_json,
    source, enforced, evaluated_at
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)";

const SELECT_RECENT_POLICY_DECISIONS_FOR_CANVAS_SQL: &str = "
SELECT id, recorded_at, canvas_id, revision, action, decision_tag, reason_code,
    policy_version, workflow, subject_json, evidence_json, visited_node_ids_json,
    source, enforced, evaluated_at
FROM policy_decisions
WHERE canvas_id = ?1 OR canvas_id IS NULL
ORDER BY recorded_at DESC, id DESC
LIMIT ?2";

const PRUNE_POLICY_DECISIONS_SQL: &str = "
DELETE FROM policy_decisions
WHERE id NOT IN (
    SELECT id FROM policy_decisions
    ORDER BY recorded_at DESC, id DESC
    LIMIT ?1
)";

/// Persist one recorded enforced decision.
///
/// # Errors
/// Returns [`CliError`] on payload serialization or SQL failure.
pub async fn record_policy_decision_row<D: PolicyGraphStore>(
    db: &D,
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
        .bind(decision.input.evaluated_at.as_deref())
        .execute(db.pool())
        .await
        .map_err(|error| db_error(format!("record policy decision {}: {error}", decision.id)))?;
    Ok(())
}

/// Read the most recent recorded decisions for one canvas, newest first.
///
/// Scopes the feed to rows the given canvas produced, plus legacy rows with
/// no recorded provenance, so replay compares a draft against its own
/// canvas's history rather than decisions another canvas governed.
///
/// Reconstructs each [`RecordedPolicyDecision`] from its columnar row so the
/// replay feature can re-simulate the current draft against real historical
/// inputs.
///
/// # Errors
/// Returns [`CliError`] on SQL failure or when a stored payload cannot be
/// decoded back into its domain type.
pub async fn recent_policy_decisions_for_canvas<D: PolicyGraphStore>(
    db: &D,
    canvas_id: &str,
    limit: usize,
) -> Result<Vec<RecordedPolicyDecision>, CliError> {
    let limit = i64::try_from(limit).unwrap_or(i64::MAX);
    let rows: Vec<PolicyDecisionRow> = query_as(SELECT_RECENT_POLICY_DECISIONS_FOR_CANVAS_SQL)
        .bind(canvas_id)
        .bind(limit)
        .fetch_all(db.pool())
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
pub async fn prune_policy_decisions<D: PolicyGraphStore>(
    db: &D,
    keep: usize,
) -> Result<u64, CliError> {
    let keep = i64::try_from(keep).unwrap_or(i64::MAX);
    let result = query(PRUNE_POLICY_DECISIONS_SQL)
        .bind(keep)
        .execute(db.pool())
        .await
        .map_err(|error| db_error(format!("prune policy decisions: {error}")))?;
    Ok(result.rows_affected())
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
    evaluated_at: Option<String>,
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
                evaluated_at: self.evaluated_at,
                approvals: Vec::new(),
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
