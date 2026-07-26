use sqlx::{Sqlite, Transaction};

use super::super::remote_assignment_lease::commit_noop;
use super::super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    nonblank,
};
use super::super::remote_assignment_rejection::apply_rejected_offer;
use super::super::remote_offer_receipts::load_offer_receipt_collisions_in_tx;
use super::super::remote_source_bundle_abandonment::source_offer_is_abandoned_in_tx;
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferDisposition, RemoteOfferResponse,
};

/// Either the screen already settled the transaction, or it hands both the
/// transaction and the record back so the caller can go on writing.
pub(super) enum OfferScreen<'c> {
    Settled(TaskBoardRemoteMutationOutcome),
    Proceed(Transaction<'c, Sqlite>, TaskBoardRemoteAssignmentRecord),
}

/// The only thing that differs between screening a live offer response and
/// screening a predecessor-acceptance recovery: what each refusal is called.
pub(super) struct OfferScreenLabels {
    pub(super) principal: &'static str,
    pub(super) observed: &'static str,
    pub(super) validate: &'static str,
    pub(super) abandoned: &'static str,
    pub(super) replayed: &'static str,
    pub(super) conflict: &'static str,
}

/// The pre-transaction checks both offer paths run before opening anything.
/// The observation time is parsed only to prove it is canonical; nothing reads
/// the parsed value.
pub(super) fn validate_offer_request(
    authenticated_principal: &str,
    observed_at: &str,
    labels: &OfferScreenLabels,
) -> Result<(), CliError> {
    nonblank(authenticated_principal, labels.principal)?;
    canonical_time(observed_at, labels.observed)?;
    Ok(())
}

/// Hand the transaction to whichever terminal path the response's disposition
/// names. Both arms consume the transaction and settle it themselves.
pub(super) async fn apply_offer_disposition(
    transaction: Transaction<'_, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    response: &RemoteOfferResponse,
    observed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    match response.disposition {
        RemoteOfferDisposition::Accepted => {
            Box::pin(super::apply_accepted_offer(
                transaction,
                record,
                response,
                observed_at,
            ))
            .await
        }
        RemoteOfferDisposition::Rejected => {
            Box::pin(apply_rejected_offer(
                transaction,
                record,
                response,
                observed_at,
            ))
            .await
        }
    }
}

/// Validate an offer response against the offer the record actually holds,
/// refuse it if the source bundle behind that offer has been abandoned, and
/// resolve it against any immutable receipt already on file: a single exact
/// replay settles as `Replayed`, while any other collision is a genuine
/// conflict against evidence that must never be rewritten.
///
/// Takes the transaction and the record by value because every refusal here
/// either commits a no-op or reports the record back to the caller, and both
/// consume what they are given.
pub(super) async fn screen_offer_response_in_tx<'c>(
    mut transaction: Transaction<'c, Sqlite>,
    record: TaskBoardRemoteAssignmentRecord,
    response: &RemoteOfferResponse,
    authenticated_principal: &str,
    labels: &OfferScreenLabels,
) -> Result<OfferScreen<'c>, CliError> {
    let offer = record.require_offer()?;
    let validate = response.validate(offer);
    validate.map_err(|error| db_error(format!("{}: {error}", labels.validate)))?;
    if source_offer_is_abandoned_in_tx(&mut transaction, offer).await? {
        commit_noop(transaction, labels.abandoned).await?;
        return Ok(OfferScreen::Settled(TaskBoardRemoteMutationOutcome::Stale(
            record,
        )));
    }
    let receipts = load_offer_receipt_collisions_in_tx(&mut transaction, offer).await?;
    if !receipts.is_empty() {
        if receipts.len() == 1
            && receipts[0].is_exact_replay(offer, authenticated_principal)
            && receipts[0].response()? == *response
        {
            commit_noop(transaction, labels.replayed).await?;
            return Ok(OfferScreen::Settled(
                TaskBoardRemoteMutationOutcome::Replayed(record),
            ));
        }
        return Err(concurrent(labels.conflict));
    }
    Ok(OfferScreen::Proceed(transaction, record))
}
