use sqlx::{Sqlite, Transaction, query_scalar};

use super::super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, exact_offer_replay, load_assignment_in_tx, to_i64,
};
use super::super::remote_operation_trust::TaskBoardRemoteOperationTrustFence;
use super::super::remote_outbound_sources::exact_outbound_source_content_in_tx;
use super::super::remote_source_bundle_reassignment_evidence::{
    SourceReassignmentEvidence, require_reassignment_evidence_in_tx,
};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;

pub(super) async fn replayed_replacement_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    evidence: SourceReassignmentEvidence<'_>,
    replacement: &RemoteOfferRequest,
    principal: &str,
    trust: &TaskBoardRemoteOperationTrustFence,
) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
    let existing = load_assignment_in_tx(transaction, &replacement.binding.assignment_id).await?;
    match existing {
        None => Ok(None),
        Some(existing) if exact_offer_replay(&existing, replacement, principal) => {
            let predecessor = load_assignment_in_tx(
                transaction,
                &evidence.offer().binding.assignment_id,
            )
            .await?
            .ok_or_else(|| concurrent("replayed source predecessor disappeared"))?;
            require_reassignment_evidence_in_tx(
                transaction,
                &predecessor,
                evidence,
                principal,
                trust,
            )
            .await?;
            let source_content =
                exact_outbound_source_content_in_tx(transaction, replacement).await?;
            require_reassignment_handoff_in_tx(transaction, &predecessor, &existing).await?;
            if source_content.is_empty() {
                return Err(concurrent("replayed source bundle is empty"));
            }
            Ok(Some(existing))
        }
        Some(_) => Err(concurrent(
            "replacement source assignment identity conflicts",
        )),
    }
}

async fn require_reassignment_handoff_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    predecessor: &TaskBoardRemoteAssignmentRecord,
    successor: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    let exact = query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM task_board_remote_assignments
           WHERE assignment_id = ?1 AND fencing_epoch = ?2
             AND state = 'superseded'
             AND controller_handoff_kind = 'remote_reassigned'
             AND controller_handoff_successor_assignment_id = ?3
             AND controller_handoff_successor_fencing_epoch = ?4
         )",
    )
    .bind(&predecessor.assignment_id)
    .bind(to_i64(
        predecessor.fencing_epoch,
        "replayed predecessor fencing epoch",
    )?)
    .bind(&successor.assignment_id)
    .bind(to_i64(
        successor.fencing_epoch,
        "replayed successor fencing epoch",
    )?)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load replayed reassignment handoff: {error}")))?;
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "replayed source reassignment lost its atomic handoff evidence",
        ))
    }
}
