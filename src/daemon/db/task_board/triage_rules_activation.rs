use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::triage_apply_rules::ActiveRuleSetEvaluator;
use super::triage_rules_reevaluation::reevaluate_all_triage_eligible_items_in_tx;
use super::triage_rules_store::{
    is_canonical_triage_rule_set_actor, record_triage_rule_set_audit_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{
    TriageRuleSetActivationResult, TriageRuleSetAuditKind, TriageRuleSetV1,
    TriageRuleSetValidationReport, validate_triage_rule_set,
};
use harness_kernel::errors::CliErrorKind;

impl AsyncDaemonDb {
    /// CAS-activate `candidate`, or deactivate back to the `BuiltInV1`
    /// default when `candidate` is `None`. Validates first: an invalid
    /// candidate is rejected atomically with a typed `activation_rejected`
    /// audit row and never reaches the revision table or touches a single
    /// item. A successful activation supersedes whatever was active,
    /// appends one new immutable revision, and bulk-reevaluates every
    /// triage-eligible item against it, all inside the one immediate
    /// transaction this function owns -- no partially written revision or
    /// partially applied evaluator identity is ever observable to a
    /// concurrent reader, and any failure after the CAS check rolls the
    /// whole activation back with no side effect at all.
    pub(crate) async fn activate_task_board_triage_rules(
        &self,
        candidate: Option<TriageRuleSetV1>,
        actor: String,
        expected_active_revision: Option<i64>,
    ) -> Result<TriageRuleSetActivationResult, CliError> {
        if !is_canonical_triage_rule_set_actor(&actor) {
            return Err(db_error(
                "triage rule set activation actor is not canonical",
            ));
        }
        let validation = candidate
            .as_ref()
            .map(validate_triage_rule_set)
            .unwrap_or_default();
        let now = utc_now();
        let mut transaction = self
            .begin_immediate_transaction("task board triage rules activation")
            .await?;
        let current_active_revision = current_active_revision_in_tx(&mut transaction).await?;
        if current_active_revision != expected_active_revision {
            return Err(CliErrorKind::concurrent_modification(format!(
                "active task board triage rule set revision changed from {expected_active_revision:?} to {current_active_revision:?}"
            ))
            .into());
        }
        if !validation.is_valid() {
            return commit_rule_set_rejection(
                transaction,
                validation,
                current_active_revision,
                &actor,
                &now,
            )
            .await;
        }
        let (new_revision, reevaluated_item_count) = apply_rule_set_activation_in_tx(
            &mut transaction,
            candidate.as_ref(),
            current_active_revision,
            &actor,
            &now,
        )
        .await?;
        commit(transaction, "task board triage rules activation").await?;
        Ok(TriageRuleSetActivationResult {
            validation,
            activated: true,
            revision: new_revision,
            reevaluated_item_count,
        })
    }
}

/// Rejects atomically: the typed `activation_rejected` audit row and the
/// commit that publishes it are the only writes, so the revision table and
/// every item stay untouched.
async fn commit_rule_set_rejection(
    mut transaction: Transaction<'_, Sqlite>,
    validation: TriageRuleSetValidationReport,
    current_active_revision: Option<i64>,
    actor: &str,
    now: &str,
) -> Result<TriageRuleSetActivationResult, CliError> {
    let validation_json = serde_json::to_string(&validation).map_err(|error| {
        db_error(format!(
            "encode rejected task board triage rule set validation: {error}"
        ))
    })?;
    record_triage_rule_set_audit_in_tx(
        &mut transaction,
        TriageRuleSetAuditKind::ActivationRejected,
        None,
        actor,
        Some("candidate failed validation"),
        Some(&validation_json),
        None,
        now,
    )
    .await?;
    commit(transaction, "task board triage rules activation rejection").await?;
    Ok(TriageRuleSetActivationResult {
        validation,
        activated: false,
        revision: current_active_revision,
        reevaluated_item_count: 0,
    })
}

async fn apply_rule_set_activation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    candidate: Option<&TriageRuleSetV1>,
    current_active_revision: Option<i64>,
    actor: &str,
    now: &str,
) -> Result<(Option<i64>, usize), CliError> {
    if let Some(revision) = current_active_revision {
        supersede_active_revision_in_tx(transaction, revision, now).await?;
    }
    let new_revision = match candidate {
        Some(candidate) => {
            Some(insert_new_active_revision_in_tx(transaction, candidate, actor, now).await?)
        }
        None => None,
    };
    let active_evaluator = active_rule_set_evaluator(new_revision, candidate)?;
    let reevaluated_item_count =
        reevaluate_all_triage_eligible_items_in_tx(transaction, active_evaluator.as_ref(), now)
            .await?;
    // Always records one audit row per successful call, including a
    // repeated deactivation when nothing was already active: the audit
    // trail is a record of actor-initiated actions against the CAS
    // pointer, not only of resulting state deltas, and the reevaluation
    // above is already a genuine no-op for decisions/placement in that
    // case (see `triage_rules_reevaluation`) -- this row only says an
    // operator asked for that state, which is worth keeping.
    record_triage_rule_set_audit_in_tx(
        transaction,
        activation_audit_kind(candidate.is_some()),
        new_revision,
        actor,
        None,
        None,
        i64::try_from(reevaluated_item_count).ok(),
        now,
    )
    .await?;
    Ok((new_revision, reevaluated_item_count))
}

fn active_rule_set_evaluator(
    new_revision: Option<i64>,
    candidate: Option<&TriageRuleSetV1>,
) -> Result<Option<ActiveRuleSetEvaluator>, CliError> {
    new_revision
        .zip(candidate)
        .map(|(revision, rules)| {
            u32::try_from(revision)
                .map(|evaluator_version| ActiveRuleSetEvaluator {
                    rules: rules.clone(),
                    evaluator_version,
                })
                .map_err(|_| db_error("activated task board triage rule set revision out of range"))
        })
        .transpose()
}

const fn activation_audit_kind(activated: bool) -> TriageRuleSetAuditKind {
    if activated {
        TriageRuleSetAuditKind::Activated
    } else {
        TriageRuleSetAuditKind::Deactivated
    }
}

async fn commit(transaction: Transaction<'_, Sqlite>, context: &str) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {context}: {error}")))
}

async fn current_active_revision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Option<i64>, CliError> {
    query_scalar::<_, i64>(
        "SELECT revision FROM task_board_triage_rule_set_revisions WHERE status = 'active'",
    )
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "read active task board triage rule set revision: {error}"
        ))
    })
}

async fn supersede_active_revision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    revision: i64,
    now: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_triage_rule_set_revisions
         SET status = 'superseded', superseded_at = ?2
         WHERE revision = ?1 AND status = 'active'",
    )
    .bind(revision)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "supersede task board triage rule set revision: {error}"
        ))
    })?;
    Ok(())
}

async fn insert_new_active_revision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    candidate: &TriageRuleSetV1,
    actor: &str,
    now: &str,
) -> Result<i64, CliError> {
    let next_revision = query_scalar::<_, i64>(
        "SELECT COALESCE(MAX(revision), 0) + 1 FROM task_board_triage_rule_set_revisions",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "compute next task board triage rule set revision: {error}"
        ))
    })?;
    let rules_json = serde_json::to_string(candidate).map_err(|error| {
        db_error(format!(
            "encode task board triage rule set revision: {error}"
        ))
    })?;
    query(
        "INSERT INTO task_board_triage_rule_set_revisions (
             revision, schema_version, rules_json, status, actor, activated_at, superseded_at
         ) VALUES (?1, ?2, ?3, 'active', ?4, ?5, NULL)",
    )
    .bind(next_revision)
    .bind(i64::from(candidate.schema_version))
    .bind(&rules_json)
    .bind(actor)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "insert task board triage rule set revision: {error}"
        ))
    })?;
    Ok(next_revision)
}

#[cfg(test)]
#[path = "triage_rules_activation_tests.rs"]
mod tests;
