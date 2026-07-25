use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteOfferOutcome, TaskBoardRemoteOfferWindow};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardExecutionAttemptCas, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
};

use super::{
    TaskBoardRemoteControllerReport, canonical_now, prepare_candidate_source,
    remote_preparing_attempt, requests, select_local_target, warn_offer_render_refused,
};

/// Offers one candidate execution to a remote host. Every way a candidate can
/// fail to go remote ends the same way - select the local target and return -
/// so `Ok(())` means "this candidate is settled", not "an offer was made". Only
/// a broken provenance invariant returns `Err` and aborts the whole pass.
pub(super) async fn offer_remote_candidate(
    db: &AsyncDaemonDb,
    report: &mut TaskBoardRemoteControllerReport,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), CliError> {
    let Some(attempt) = remote_preparing_attempt(execution) else {
        return Ok(());
    };
    let Some(phase) = execution.transition.phase else {
        return Ok(());
    };
    let now = canonical_now();
    let prior_bundle = if requests::requires_prior_bundle(execution, phase) {
        db.task_board_remote_prior_phase_bundle(execution, phase)
            .await?
    } else {
        None
    };
    let Some(prepared_source) =
        prepare_candidate_source(execution, phase, prior_bundle.as_ref()).await?
    else {
        select_local_target(db, execution, attempt, &now).await?;
        return Ok(());
    };
    let source_repository = prepared_source.repository().to_owned();
    let host = db
        .resolve_task_board_remote_host(execution, &source_repository, phase, "codex", &now)
        .await?;
    let Some(host) = host else {
        select_local_target(db, execution, attempt, &now).await?;
        return Ok(());
    };
    // Sealing the offer renders the prompt, and a configured prompt can
    // fail to render for this one execution -- a name the execution has no
    // value for, or a template past the remote request's size ceiling.
    // That is this candidate's problem, not the pass's: propagating it
    // aborted the whole controller pass, which is a precondition of every
    // dispatch route, so one bad candidate stopped every unrelated item
    // from dispatching on every tick until the daemon restarted. Refusing
    // remote and letting it run locally is what the neighbouring branches
    // already do when a candidate cannot go remote.
    let prepared = match requests::prepare_offer(execution, attempt, &host, prepared_source, &now) {
        Ok(prepared) => prepared,
        Err(error) => {
            warn_offer_render_refused(&execution.execution_id, &error);
            select_local_target(db, execution, attempt, &now).await?;
            return Ok(());
        }
    };
    let Some(prepared) = prepared else {
        select_local_target(db, execution, attempt, &now).await?;
        return Ok(());
    };
    match Box::pin(db.offer_task_board_remote_assignment_with_source(
        &TaskBoardWorkflowExecutionCas::from(execution),
        &TaskBoardExecutionAttemptCas::from(attempt),
        &prepared.request,
        prepared.source_content.as_deref(),
        &host.config.host_id,
        TaskBoardRemoteOfferWindow::new(
            &prepared.offered_at,
            &prepared.lease_expires_at,
            &prepared.deadline_at,
        ),
    ))
    .await?
    {
        TaskBoardRemoteOfferOutcome::Created(_) | TaskBoardRemoteOfferOutcome::Replayed(_) => {
            report.offered_attempts += 1;
        }
        // AcceptedReplay/Rejected carry executor-inbox receipts and are produced only by the
        // executor offer inbox, never by offer_task_board_remote_assignment_with_source
        // (Created/Replayed/Stale/Unavailable only). Fail closed rather than silently falling
        // back to local at this pre-I/O offer boundary if that provenance invariant is broken.
        TaskBoardRemoteOfferOutcome::AcceptedReplay(_)
        | TaskBoardRemoteOfferOutcome::Rejected(_) => {
            return Err(CliErrorKind::concurrent_modification(
                "controller offer creation returned an executor-inbox receipt outcome",
            )
            .into());
        }
        TaskBoardRemoteOfferOutcome::Unavailable | TaskBoardRemoteOfferOutcome::Stale => {}
    }
    Ok(())
}
