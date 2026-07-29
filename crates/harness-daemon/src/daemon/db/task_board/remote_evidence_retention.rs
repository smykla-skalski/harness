use chrono::Duration;
use sqlx::{Sqlite, Transaction, query};

use super::remote_assignment_model::canonical_time;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

pub(super) const REMOTE_EVIDENCE_RETENTION_DAYS: i64 = 7;
const REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT: i64 = 100;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteEvidencePruneResult {
    pub(crate) artifacts: u64,
    pub(crate) source_bundle_contents: u64,
    pub(crate) offer_receipts: u64,
    pub(crate) settlement_receipts: u64,
}

impl AsyncDaemonDb {
    pub(crate) async fn prune_task_board_remote_execution_evidence(
        &self,
        now: &str,
    ) -> Result<TaskBoardRemoteEvidencePruneResult, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board remote evidence retention")
            .await?;
        let result = prune_remote_evidence_in_tx(&mut transaction, now).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote evidence retention: {error}")))?;
        Ok(result)
    }
}

pub(super) async fn prune_remote_evidence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    now: &str,
) -> Result<TaskBoardRemoteEvidencePruneResult, CliError> {
    let now = canonical_time(now, "remote evidence retention time")?;
    let cutoff = (now - Duration::days(REMOTE_EVIDENCE_RETENTION_DAYS))
        .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    let artifacts = prune_artifacts(transaction, &cutoff).await?;
    let source_bundle_contents = prune_source_bundle_contents(transaction, &cutoff).await?;
    let offer_receipts = prune_offer_receipts(transaction, &cutoff).await?;
    let settlement_receipts = prune_settlement_receipts(transaction, &cutoff).await?;
    Ok(TaskBoardRemoteEvidencePruneResult {
        artifacts,
        source_bundle_contents,
        offer_receipts,
        settlement_receipts,
    })
}

async fn prune_artifacts(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    query(
        "DELETE FROM task_board_remote_artifacts
         WHERE (assignment_id, fencing_epoch) IN (
           SELECT artifact.assignment_id, artifact.fencing_epoch
           FROM task_board_remote_artifacts AS artifact
           JOIN task_board_remote_assignments AS assignment
             ON assignment.assignment_id = artifact.assignment_id
            AND assignment.fencing_epoch = artifact.fencing_epoch
           LEFT JOIN task_board_remote_settlement_receipts AS settlement
             ON settlement.assignment_id = artifact.assignment_id
            AND settlement.fencing_epoch = artifact.fencing_epoch
           WHERE assignment.state IN (
                   'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                 )
             AND NOT EXISTS (
               SELECT 1
               FROM task_board_remote_result_imports AS result_import
               WHERE result_import.assignment_id = artifact.assignment_id
                 AND result_import.fencing_epoch = artifact.fencing_epoch
                 AND result_import.state IN ('prepared', 'applied')
             )
             AND julianday(assignment.deadline_at) < julianday(?1)
             AND (
               assignment.completed_at IS NULL
               OR julianday(assignment.completed_at) < julianday(?1)
             )
             AND (
               settlement.settled_at IS NULL
               OR julianday(settlement.settled_at) < julianday(?1)
             )
             AND NOT EXISTS (
               SELECT 1
               FROM task_board_remote_result_imports AS origin
               JOIN task_board_workflow_executions AS workflow
                 ON workflow.execution_id = origin.execution_id
               JOIN task_board_remote_artifacts AS origin_bundle
                 ON origin_bundle.assignment_id = origin.assignment_id
                AND origin_bundle.fencing_epoch = origin.fencing_epoch
                AND origin_bundle.relative_path = 'result/implementation.bundle'
               WHERE origin.assignment_id = artifact.assignment_id
                 AND origin.fencing_epoch = artifact.fencing_epoch
                 AND origin.state = 'adopted'
                 AND workflow.state NOT IN (
                   'human_required', 'completed', 'failed', 'cancelled'
                 )
                 AND NOT EXISTS (
                   SELECT 1
                   FROM task_board_remote_source_bundles AS materialized
                   WHERE materialized.execution_id = origin.execution_id
                     AND materialized.base_revision = origin.base_revision
                     AND materialized.result_revision = origin.result_revision
                     AND materialized.sha256 = origin.bundle_sha256
                     AND materialized.content_pruned_at IS NULL
                     AND length(materialized.content) = materialized.size_bytes
                 )
             )
           GROUP BY artifact.assignment_id, artifact.fencing_epoch
           ORDER BY julianday(assignment.deadline_at), artifact.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune remote artifact evidence: {error}")))
}

async fn prune_source_bundle_contents(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    let settled = query(
        "UPDATE task_board_remote_source_bundles
         SET content = X'', content_pruned_at = ?1
         WHERE (assignment_id, fencing_epoch) IN (
           SELECT source.assignment_id, source.fencing_epoch
           FROM task_board_remote_source_bundles AS source
           JOIN task_board_remote_assignments AS assignment
             ON assignment.assignment_id = source.assignment_id
            AND assignment.fencing_epoch = source.fencing_epoch
           JOIN task_board_remote_settlement_receipts AS settlement
             ON settlement.assignment_id = source.assignment_id
            AND settlement.fencing_epoch = source.fencing_epoch
           WHERE source.content_pruned_at IS NULL
             AND assignment.state IN (
               'completed', 'failed', 'cancelled', 'superseded', 'unknown'
             )
             AND assignment.cleanup_completed_at IS NOT NULL
             AND julianday(assignment.cleanup_completed_at) < julianday(?1)
             AND julianday(settlement.settled_at) < julianday(?1)
             AND julianday(assignment.deadline_at) < julianday(?1)
             AND NOT EXISTS (
               SELECT 1
               FROM task_board_remote_result_imports AS origin
               JOIN task_board_workflow_executions AS workflow
                 ON workflow.execution_id = origin.execution_id
               WHERE origin.state = 'adopted'
                 AND workflow.state NOT IN (
                   'human_required', 'completed', 'failed', 'cancelled'
                 )
                 AND source.execution_id = origin.execution_id
                 AND source.base_revision = origin.base_revision
                 AND source.result_revision = origin.result_revision
                 AND source.sha256 = origin.bundle_sha256
                 AND NOT EXISTS (
                   SELECT 1
                   FROM task_board_remote_artifacts AS origin_bundle
                   WHERE origin_bundle.assignment_id = origin.assignment_id
                     AND origin_bundle.fencing_epoch = origin.fencing_epoch
                     AND origin_bundle.relative_path = 'result/implementation.bundle'
                     AND origin_bundle.sha256 = origin.bundle_sha256
                     AND origin_bundle.size_bytes = source.size_bytes
                     AND length(origin_bundle.content) = origin_bundle.size_bytes
                 )
             )
           ORDER BY julianday(assignment.cleanup_completed_at), source.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune remote source bundle content: {error}")))?;
    let settled_outbound = prune_settled_outbound_source_contents(transaction, cutoff).await?;
    let rejected_orphan = prune_rejected_orphan_source_bundle_contents(transaction, cutoff).await?;
    let abandoned = prune_abandoned_outbound_source_contents(transaction, cutoff).await?;
    let outbound = prune_reassigned_outbound_source_contents(transaction, cutoff).await?;
    settled
        .checked_add(settled_outbound)
        .and_then(|total| total.checked_add(rejected_orphan))
        .and_then(|total| total.checked_add(abandoned))
        .and_then(|total| total.checked_add(outbound))
        .ok_or_else(|| db_error("remote source retention count overflow"))
}

async fn prune_rejected_orphan_source_bundle_contents(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    query(
        "UPDATE task_board_remote_source_bundles
         SET content = X'', content_pruned_at = ?1
         WHERE (assignment_id, fencing_epoch) IN (
           SELECT source.assignment_id, source.fencing_epoch
           FROM task_board_remote_source_bundles AS source
           JOIN task_board_remote_offer_receipts AS receipt
             ON receipt.assignment_id = source.assignment_id
            AND receipt.fencing_epoch = source.fencing_epoch
            AND receipt.request_sha256 = source.offer_request_sha256
            AND receipt.authenticated_principal = source.authenticated_principal
            AND receipt.disposition = 'rejected'
           LEFT JOIN task_board_remote_assignments AS assignment
             ON assignment.assignment_id = source.assignment_id
            AND assignment.fencing_epoch = source.fencing_epoch
           WHERE source.content_pruned_at IS NULL
             AND assignment.assignment_id IS NULL
             AND julianday(receipt.received_at) < julianday(?1)
             AND julianday(json_extract(source.offer_json, '$.deadline_at')) < julianday(?1)
           ORDER BY julianday(receipt.received_at), source.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune rejected orphan source bundle: {error}")))
}

async fn prune_settled_outbound_source_contents(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    query(
        "UPDATE task_board_remote_outbound_sources
         SET content = X'', content_pruned_at = ?1
         WHERE (assignment_id, fencing_epoch) IN (
           SELECT source.assignment_id, source.fencing_epoch
           FROM task_board_remote_outbound_sources AS source
           JOIN task_board_remote_assignments AS assignment
             ON assignment.assignment_id = source.assignment_id
            AND assignment.fencing_epoch = source.fencing_epoch
           JOIN task_board_remote_settlement_receipts AS settlement
             ON settlement.assignment_id = source.assignment_id
            AND settlement.fencing_epoch = source.fencing_epoch
           WHERE source.content_pruned_at IS NULL
             AND assignment.state IN (
               'completed', 'failed', 'cancelled', 'superseded', 'unknown'
             )
             AND assignment.cleanup_completed_at IS NOT NULL
             AND julianday(assignment.cleanup_completed_at) < julianday(?1)
             AND julianday(settlement.settled_at) < julianday(?1)
             AND julianday(assignment.deadline_at) < julianday(?1)
             AND NOT EXISTS (
               SELECT 1
               FROM task_board_remote_result_imports AS origin
               JOIN task_board_workflow_executions AS workflow
                 ON workflow.execution_id = origin.execution_id
               WHERE origin.state = 'adopted'
                 AND workflow.state NOT IN (
                   'human_required', 'completed', 'failed', 'cancelled'
                 )
                 AND source.execution_id = origin.execution_id
                 AND source.base_revision = origin.base_revision
                 AND source.result_revision = origin.result_revision
                 AND source.sha256 = origin.bundle_sha256
                 AND NOT EXISTS (
                   SELECT 1
                   FROM task_board_remote_artifacts AS origin_bundle
                   WHERE origin_bundle.assignment_id = origin.assignment_id
                     AND origin_bundle.fencing_epoch = origin.fencing_epoch
                     AND origin_bundle.relative_path = 'result/implementation.bundle'
                     AND origin_bundle.sha256 = origin.bundle_sha256
                     AND origin_bundle.size_bytes = source.size_bytes
                     AND length(origin_bundle.content) = origin_bundle.size_bytes
                 )
                 AND NOT EXISTS (
                   SELECT 1
                   FROM task_board_remote_source_bundles AS materialized
                   WHERE materialized.execution_id = origin.execution_id
                     AND materialized.base_revision = origin.base_revision
                     AND materialized.result_revision = origin.result_revision
                     AND materialized.sha256 = origin.bundle_sha256
                     AND materialized.size_bytes = source.size_bytes
                     AND materialized.content_pruned_at IS NULL
                     AND length(materialized.content) = materialized.size_bytes
                 )
             )
           ORDER BY julianday(assignment.cleanup_completed_at), source.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune settled remote outbound source: {error}")))
}

async fn prune_abandoned_outbound_source_contents(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    query(
        "UPDATE task_board_remote_outbound_sources
         SET content = X'', content_pruned_at = ?1
         WHERE (assignment_id, fencing_epoch) IN (
           SELECT source.assignment_id, source.fencing_epoch
           FROM task_board_remote_outbound_sources AS source
           JOIN task_board_remote_source_bundle_abandonments AS abandoned
             ON abandoned.assignment_id = source.assignment_id
            AND abandoned.fencing_epoch = source.fencing_epoch
            AND abandoned.offer_request_sha256 = source.offer_request_sha256
            AND abandoned.upload_request_sha256 = source.upload_request_sha256
           JOIN task_board_remote_assignments AS assignment
             ON assignment.assignment_id = source.assignment_id
            AND assignment.fencing_epoch = source.fencing_epoch
           WHERE source.content_pruned_at IS NULL
             AND (
               (assignment.state = 'superseded'
                AND assignment.controller_handoff_kind = 'local_fallback')
               OR (assignment.state IN (
                     'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                   )
                   AND assignment.controller_handoff_kind IN (
                     'result_adopted', 'evidence_only', 'terminal_projection',
                     'terminal_cleanup'
                   ))
             )
             AND julianday(assignment.controller_handoff_at) < julianday(?1)
             AND julianday(abandoned.abandoned_at) < julianday(?1)
             AND julianday(assignment.deadline_at) < julianday(?1)
           ORDER BY julianday(abandoned.abandoned_at), source.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune abandoned remote outbound source: {error}")))
}

async fn prune_reassigned_outbound_source_contents(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    query(
        "UPDATE task_board_remote_outbound_sources
         SET content = X'', content_pruned_at = ?1
         WHERE (assignment_id, fencing_epoch) IN (
           SELECT source.assignment_id, source.fencing_epoch
           FROM task_board_remote_outbound_sources AS source
           JOIN task_board_remote_assignments AS predecessor
             ON predecessor.assignment_id = source.assignment_id
            AND predecessor.fencing_epoch = source.fencing_epoch
           JOIN task_board_remote_assignments AS successor
             ON successor.assignment_id = predecessor.controller_handoff_successor_assignment_id
            AND successor.fencing_epoch = predecessor.controller_handoff_successor_fencing_epoch
            AND successor.execution_id = predecessor.execution_id
           JOIN task_board_remote_outbound_sources AS replacement
             ON replacement.assignment_id = successor.assignment_id
            AND replacement.fencing_epoch = successor.fencing_epoch
           WHERE source.content_pruned_at IS NULL
             AND predecessor.state = 'superseded'
             AND predecessor.controller_handoff_kind = 'remote_reassigned'
             AND julianday(predecessor.controller_handoff_at) < julianday(?1)
             AND julianday(predecessor.deadline_at) < julianday(?1)
             AND replacement.content_pruned_at IS NULL
             AND length(replacement.content) = replacement.size_bytes
             AND replacement.repository = source.repository
             AND replacement.base_revision = source.base_revision
             AND replacement.result_revision = source.result_revision
             AND replacement.advertised_ref = source.advertised_ref
             AND replacement.sha256 = source.sha256
             AND replacement.size_bytes = source.size_bytes
           ORDER BY julianday(predecessor.controller_handoff_at), source.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune reassigned remote outbound source: {error}")))
}

async fn prune_offer_receipts(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    query(
        "DELETE FROM task_board_remote_offer_receipts
         WHERE assignment_id IN (
           SELECT receipt.assignment_id
           FROM task_board_remote_offer_receipts AS receipt
           LEFT JOIN task_board_remote_assignments AS assignment
             ON assignment.assignment_id = receipt.assignment_id
            AND assignment.fencing_epoch = receipt.fencing_epoch
           LEFT JOIN task_board_remote_settlement_receipts AS settlement
             ON settlement.assignment_id = receipt.assignment_id
            AND settlement.fencing_epoch = receipt.fencing_epoch
           WHERE (
               assignment.assignment_id IS NULL
               OR assignment.state IN (
                    'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                  )
             )
             AND julianday(json_extract(receipt.request_json, '$.deadline_at')) < julianday(?1)
             AND (
               assignment.assignment_id IS NULL
               OR (
                 julianday(assignment.deadline_at) < julianday(?1)
                 AND (
                   assignment.completed_at IS NULL
                   OR julianday(assignment.completed_at) < julianday(?1)
                 )
               )
             )
             AND (
               settlement.settled_at IS NULL
               OR julianday(settlement.settled_at) < julianday(?1)
             )
             AND NOT EXISTS (
               SELECT 1 FROM task_board_remote_source_bundles AS source
               WHERE source.assignment_id = receipt.assignment_id
                 AND source.fencing_epoch = receipt.fencing_epoch
                 AND source.offer_request_sha256 = receipt.request_sha256
                 AND source.authenticated_principal = receipt.authenticated_principal
                 AND source.content_pruned_at IS NULL
             )
           ORDER BY julianday(json_extract(receipt.request_json, '$.deadline_at')),
                    receipt.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune remote offer evidence: {error}")))
}

async fn prune_settlement_receipts(
    transaction: &mut Transaction<'_, Sqlite>,
    cutoff: &str,
) -> Result<u64, CliError> {
    query(
        "DELETE FROM task_board_remote_settlement_receipts
         WHERE assignment_id IN (
           SELECT settlement.assignment_id
           FROM task_board_remote_settlement_receipts AS settlement
           JOIN task_board_remote_assignments AS assignment
             ON assignment.assignment_id = settlement.assignment_id
            AND assignment.fencing_epoch = settlement.fencing_epoch
           WHERE assignment.state IN (
                   'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                 )
             AND assignment.cleanup_completed_at IS NOT NULL
             AND julianday(settlement.settled_at) < julianday(?1)
             AND julianday(assignment.deadline_at) < julianday(?1)
             AND (
               assignment.completed_at IS NULL
               OR julianday(assignment.completed_at) < julianday(?1)
             )
             AND NOT EXISTS (
               SELECT 1 FROM task_board_remote_source_bundles AS source
               WHERE source.assignment_id = settlement.assignment_id
                 AND source.fencing_epoch = settlement.fencing_epoch
                 AND source.content_pruned_at IS NULL
             )
             AND NOT EXISTS (
               SELECT 1 FROM task_board_remote_outbound_sources AS source
               WHERE source.assignment_id = settlement.assignment_id
                 AND source.fencing_epoch = settlement.fencing_epoch
                 AND source.content_pruned_at IS NULL
             )
           ORDER BY julianday(settlement.settled_at), settlement.assignment_id
           LIMIT ?2
         )",
    )
    .bind(cutoff)
    .bind(REMOTE_EVIDENCE_PRUNE_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("prune remote settlement evidence: {error}")))
}
