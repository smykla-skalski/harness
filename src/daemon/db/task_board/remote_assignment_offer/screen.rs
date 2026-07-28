use sqlx::{Sqlite, Transaction};

use super::super::remote_assignment_archival_fence::require_no_archival_collision_in_tx;
use super::super::remote_assignment_model::{
    TaskBoardRemoteOfferOutcome, load_offer_collision_in_tx,
};
use super::types::{OfferPreparation, OfferTimes};
use super::{
    PreparedRemoteOffer, commit_noop, prepare_remote_offer_in_tx, resolve_offer_collision,
};
use crate::daemon::db::CliError;
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::task_board::{TaskBoardExecutionAttemptCas, TaskBoardWorkflowExecutionCas};

/// Either the offer is already settled and the caller has nothing left to do
/// but report it, or preparation is ready and hands the still-open
/// transaction back so the caller can persist the claim on it.
pub(super) enum OfferPreparationScreen<'c> {
    Stopped(Box<TaskBoardRemoteOfferOutcome>),
    Ready(Transaction<'c, Sqlite>, Box<PreparedRemoteOffer>),
}

/// Either an archival or an in-flight collision already settled this offer,
/// or the transaction is clear of both and ready for preparation.
enum OfferCollisionScreen<'c> {
    Stopped(Box<TaskBoardRemoteOfferOutcome>),
    Clear(Transaction<'c, Sqlite>),
}

async fn screen_remote_offer_collision_in_tx<'c>(
    mut transaction: Transaction<'c, Sqlite>,
    request: &RemoteOfferRequest,
    authenticated_principal: &str,
    source_content: Option<&[u8]>,
) -> Result<OfferCollisionScreen<'c>, CliError> {
    // An identity colliding with an archived legacy row is a deterministic
    // conflict; exact replay is only ever honoured with the archive empty.
    require_no_archival_collision_in_tx(
        &mut transaction,
        &request.binding.assignment_id,
        &request.binding.idempotency_key,
        Some(&request.request_sha256),
        &request.binding.execution_id,
        request.binding.fencing_epoch,
    )
    .await?;
    let collisions = load_offer_collision_in_tx(&mut transaction, request).await?;
    if !collisions.is_empty() {
        let outcome = resolve_offer_collision(
            transaction,
            collisions,
            request,
            authenticated_principal,
            source_content,
        )
        .await?;
        return Ok(OfferCollisionScreen::Stopped(Box::new(outcome)));
    }
    Ok(OfferCollisionScreen::Clear(transaction))
}

pub(super) async fn screen_remote_offer_admission_in_tx<'c>(
    transaction: Transaction<'c, Sqlite>,
    expected_execution: &TaskBoardWorkflowExecutionCas,
    expected_attempt: &TaskBoardExecutionAttemptCas,
    request: &RemoteOfferRequest,
    authenticated_principal: &str,
    source_content: Option<&[u8]>,
    offered_at: &str,
    times: OfferTimes,
) -> Result<OfferPreparationScreen<'c>, CliError> {
    let mut transaction = match screen_remote_offer_collision_in_tx(
        transaction,
        request,
        authenticated_principal,
        source_content,
    )
    .await?
    {
        OfferCollisionScreen::Stopped(outcome) => {
            return Ok(OfferPreparationScreen::Stopped(outcome));
        }
        OfferCollisionScreen::Clear(transaction) => transaction,
    };
    match prepare_remote_offer_in_tx(
        &mut transaction,
        expected_execution,
        expected_attempt,
        request,
        offered_at,
        times,
    )
    .await?
    {
        OfferPreparation::Stale(reason) => {
            commit_noop(transaction, reason).await?;
            Ok(OfferPreparationScreen::Stopped(Box::new(
                TaskBoardRemoteOfferOutcome::Stale,
            )))
        }
        OfferPreparation::Unavailable(reason) => {
            commit_noop(transaction, reason).await?;
            Ok(OfferPreparationScreen::Stopped(Box::new(
                TaskBoardRemoteOfferOutcome::Unavailable,
            )))
        }
        OfferPreparation::Ready(prepared) => {
            Ok(OfferPreparationScreen::Ready(transaction, prepared))
        }
    }
}
