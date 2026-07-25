use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use harness_kernel::errors::CliErrorKind;
use crate::task_board::{
    TriageRuleSetAuditEntry, TriageRuleSetAuditKind, TriageRuleSetDraft,
    TriageRuleSetDraftSaveResult, TriageRuleSetRevisionStatus, TriageRuleSetRevisionSummary,
    TriageRuleSetV1, is_canonical_bounded_text, validate_triage_rule_set,
};

const MAX_TRIAGE_RULE_SET_ACTOR_BYTES: usize = 256;
pub(super) const TRIAGE_RULE_SET_LIST_MAX_LIMIT: u32 = 100;

#[derive(sqlx::FromRow)]
struct DraftRow {
    rules_json: String,
    revision: i64,
    actor: String,
    updated_at: String,
}

fn draft_from_row(row: DraftRow) -> Result<TriageRuleSetDraft, CliError> {
    Ok(TriageRuleSetDraft {
        rules: decode_rule_set(&row.rules_json)?,
        revision: row.revision,
        actor: row.actor,
        updated_at: row.updated_at,
    })
}

pub(super) fn decode_rule_set(rules_json: &str) -> Result<TriageRuleSetV1, CliError> {
    serde_json::from_str(rules_json)
        .map_err(|error| db_error(format!("decode stored triage rule set: {error}")))
}

pub(super) fn is_canonical_triage_rule_set_actor(value: &str) -> bool {
    is_canonical_bounded_text(value, MAX_TRIAGE_RULE_SET_ACTOR_BYTES)
}

impl AsyncDaemonDb {
    pub(crate) async fn load_task_board_triage_rules_draft(
        &self,
    ) -> Result<Option<TriageRuleSetDraft>, CliError> {
        let row = query_as::<_, DraftRow>(
            "SELECT rules_json, revision, actor, updated_at
             FROM task_board_triage_rule_set_draft WHERE singleton = 1",
        )
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load task board triage rules draft: {error}")))?;
        row.map(draft_from_row).transpose()
    }

    /// CAS-save a draft candidate. `expected_revision` must be `None` when no
    /// draft exists yet, or the draft's current revision to replace it -- a
    /// mismatch means a concurrent editor already moved it. A candidate that
    /// fails validation is never persisted -- the existing draft (if any)
    /// stays exactly as it was, and the caller sees why in `validation`.
    pub(crate) async fn save_task_board_triage_rules_draft(
        &self,
        candidate: TriageRuleSetV1,
        actor: String,
        expected_revision: Option<i64>,
    ) -> Result<TriageRuleSetDraftSaveResult, CliError> {
        if !is_canonical_triage_rule_set_actor(&actor) {
            return Err(db_error("triage rule set draft actor is not canonical"));
        }
        let validation = validate_triage_rule_set(&candidate);
        let mut transaction = self
            .begin_immediate_transaction("task board triage rules draft save")
            .await?;
        let current_revision =
            query_scalar::<_, i64>("SELECT revision FROM task_board_triage_rule_set_draft WHERE singleton = 1")
                .fetch_optional(transaction.as_mut())
                .await
                .map_err(|error| db_error(format!("read task board triage rules draft revision: {error}")))?;
        if current_revision != expected_revision {
            return Err(CliErrorKind::concurrent_modification(format!(
                "task board triage rule set draft revision changed from {expected_revision:?} to {current_revision:?}"
            ))
            .into());
        }
        if !validation.is_valid() {
            return Ok(TriageRuleSetDraftSaveResult {
                validation,
                persisted: false,
                revision: current_revision,
            });
        }
        let next_revision = expected_revision.unwrap_or(0) + 1;
        let rules_json = serde_json::to_string(&candidate)
            .map_err(|error| db_error(format!("encode task board triage rules draft: {error}")))?;
        let now = utc_now();
        query(
            "INSERT INTO task_board_triage_rule_set_draft (singleton, rules_json, revision, actor, updated_at)
             VALUES (1, ?1, ?2, ?3, ?4)
             ON CONFLICT(singleton) DO UPDATE SET
                 rules_json = excluded.rules_json, revision = excluded.revision,
                 actor = excluded.actor, updated_at = excluded.updated_at",
        )
        .bind(&rules_json)
        .bind(next_revision)
        .bind(&actor)
        .bind(&now)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("save task board triage rules draft: {error}")))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board triage rules draft save: {error}")))?;
        Ok(TriageRuleSetDraftSaveResult {
            validation,
            persisted: true,
            revision: Some(next_revision),
        })
    }

    pub(crate) async fn list_task_board_triage_rules_revisions(
        &self,
        limit: u32,
    ) -> Result<Vec<TriageRuleSetRevisionSummary>, CliError> {
        let limit = limit.min(TRIAGE_RULE_SET_LIST_MAX_LIMIT);
        let rows = query_as::<_, RevisionRow>(
            "SELECT revision, schema_version, rules_json, status, actor, activated_at, superseded_at
             FROM task_board_triage_rule_set_revisions
             ORDER BY revision DESC LIMIT ?1",
        )
        .bind(i64::from(limit))
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("list task board triage rule set revisions: {error}")))?;
        rows.into_iter().map(revision_summary_from_row).collect()
    }

    pub(crate) async fn list_task_board_triage_rules_audit(
        &self,
        limit: u32,
    ) -> Result<Vec<TriageRuleSetAuditEntry>, CliError> {
        let limit = limit.min(TRIAGE_RULE_SET_LIST_MAX_LIMIT);
        let rows = query_as::<_, AuditRow>(
            "SELECT audit_id, kind, revision, actor, reason, reevaluated_item_count, recorded_at
             FROM task_board_triage_rule_set_audit
             ORDER BY recorded_at DESC, audit_id DESC LIMIT ?1",
        )
        .bind(i64::from(limit))
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("list task board triage rule set audit: {error}")))?;
        rows.into_iter().map(audit_entry_from_row).collect()
    }
}

#[derive(sqlx::FromRow)]
struct RevisionRow {
    revision: i64,
    schema_version: i64,
    rules_json: String,
    status: String,
    actor: String,
    activated_at: String,
    superseded_at: Option<String>,
}

fn revision_summary_from_row(row: RevisionRow) -> Result<TriageRuleSetRevisionSummary, CliError> {
    let rules = decode_rule_set(&row.rules_json)?;
    Ok(TriageRuleSetRevisionSummary {
        revision: row.revision,
        schema_version: u16::try_from(row.schema_version)
            .map_err(|_| db_error("stored triage rule set schema version out of range"))?,
        rule_count: rules.rules.len(),
        status: parse_revision_status(&row.status)?,
        actor: row.actor,
        activated_at: row.activated_at,
        superseded_at: row.superseded_at,
    })
}

fn parse_revision_status(value: &str) -> Result<TriageRuleSetRevisionStatus, CliError> {
    match value {
        "active" => Ok(TriageRuleSetRevisionStatus::Active),
        "superseded" => Ok(TriageRuleSetRevisionStatus::Superseded),
        other => Err(db_error(format!(
            "unknown stored triage rule set revision status '{other}'"
        ))),
    }
}

#[derive(sqlx::FromRow)]
struct AuditRow {
    audit_id: String,
    kind: String,
    revision: Option<i64>,
    actor: String,
    reason: Option<String>,
    reevaluated_item_count: Option<i64>,
    recorded_at: String,
}

fn audit_entry_from_row(row: AuditRow) -> Result<TriageRuleSetAuditEntry, CliError> {
    Ok(TriageRuleSetAuditEntry {
        audit_id: row.audit_id,
        kind: parse_audit_kind(&row.kind)?,
        revision: row.revision,
        actor: row.actor,
        reason: row.reason,
        reevaluated_item_count: row.reevaluated_item_count,
        recorded_at: row.recorded_at,
    })
}

fn parse_audit_kind(value: &str) -> Result<TriageRuleSetAuditKind, CliError> {
    match value {
        "activated" => Ok(TriageRuleSetAuditKind::Activated),
        "activation_rejected" => Ok(TriageRuleSetAuditKind::ActivationRejected),
        "deactivated" => Ok(TriageRuleSetAuditKind::Deactivated),
        other => Err(db_error(format!(
            "unknown stored triage rule set audit kind '{other}'"
        ))),
    }
}

/// Insert a typed audit row inside the caller's activation transaction.
/// `validation_json` is the serialized `TriageRuleSetValidationReport` for
/// an `ActivationRejected` row -- the only durable record that a malformed
/// candidate ever existed, since it was rejected before touching the
/// revision table. Every other kind passes `None`.
#[expect(
    clippy::too_many_arguments,
    reason = "one immutable audit row, named for clarity over a bag struct"
)]
pub(super) async fn record_triage_rule_set_audit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    kind: TriageRuleSetAuditKind,
    revision: Option<i64>,
    actor: &str,
    reason: Option<&str>,
    validation_json: Option<&str>,
    reevaluated_item_count: Option<i64>,
    recorded_at: &str,
) -> Result<(), CliError> {
    let audit_id = format!("triage-rules-audit-{}", uuid::Uuid::new_v4().simple());
    query(
        "INSERT INTO task_board_triage_rule_set_audit (
             audit_id, kind, revision, actor, reason, validation_json,
             reevaluated_item_count, recorded_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    )
    .bind(&audit_id)
    .bind(audit_kind_wire(kind))
    .bind(revision)
    .bind(actor)
    .bind(reason)
    .bind(validation_json)
    .bind(reevaluated_item_count)
    .bind(recorded_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record task board triage rule set audit: {error}")))?;
    Ok(())
}

const fn audit_kind_wire(kind: TriageRuleSetAuditKind) -> &'static str {
    match kind {
        TriageRuleSetAuditKind::Activated => "activated",
        TriageRuleSetAuditKind::ActivationRejected => "activation_rejected",
        TriageRuleSetAuditKind::Deactivated => "deactivated",
    }
}

#[cfg(test)]
#[path = "triage_rules_store_tests.rs"]
mod tests;
