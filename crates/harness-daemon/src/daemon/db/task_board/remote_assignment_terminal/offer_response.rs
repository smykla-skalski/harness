use super::offer_screen::{
    OfferScreen, apply_offer_disposition, screen_offer_response_in_tx, validate_offer_request,
};
use super::{OFFER_RESPONSE_LABELS, response_binding_matches};
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::remote_assignment_lease::{commit_noop, require_assignment};
use crate::daemon::db::task_board::remote_assignment_model::TaskBoardRemoteMutationOutcome;
use crate::daemon::db::task_board::remote_operation_trust::{
    TaskBoardRemoteOperationKind, consume_controller_operation_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::remote_wire::wire::RemoteOfferResponse;

pub(crate) async fn record_task_board_remote_offer_response(
    db: &AsyncDaemonDb,
    response: &RemoteOfferResponse,
    authenticated_principal: &str,
    observed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    validate_offer_request(authenticated_principal, observed_at, &OFFER_RESPONSE_LABELS)?;
    let mut transaction = db
        .begin_immediate_transaction("task board remote offer response")
        .await?;
    let record = require_assignment(&mut transaction, &response.binding.assignment_id).await?;
    let (mut transaction, record) = match screen_offer_response_in_tx(
        transaction,
        record,
        response,
        authenticated_principal,
        &OFFER_RESPONSE_LABELS,
    )
    .await?
    {
        OfferScreen::Settled(outcome) => return Ok(outcome),
        OfferScreen::Proceed(transaction, record) => (transaction, record),
    };
    if !response_binding_matches(&record, &response.binding, authenticated_principal) {
        commit_noop(transaction, "stale offer response").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    consume_controller_operation_trust_in_tx(
        &mut transaction,
        &record,
        TaskBoardRemoteOperationKind::Offer,
        &response.offer_request_sha256,
    )
    .await?;
    apply_offer_disposition(transaction, record, response, observed_at).await
}
