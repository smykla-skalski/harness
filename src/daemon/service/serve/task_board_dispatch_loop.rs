use std::time::Duration;

use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};
use tracing::warn;

use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatch, TaskBoardDispatchClaimAction};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::service::task_board::prepare_claimed_task_board_dispatch;
use crate::daemon::task_board_managed_agents::{
    maintain_task_board_dispatch_claim, managed_worker_id, resume_worker_compensation,
    settle_claimed_task_board_worker,
};

const RECOVERY_INTERVAL: Duration = Duration::from_secs(1);
const MAX_RECOVERIES_PER_TICK: usize = 16;

pub(super) fn spawn_task_board_dispatch_loop(
    state: DaemonHttpState,
    shutdown_rx: watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_task_board_dispatch_loop(state, shutdown_rx))
}

async fn run_task_board_dispatch_loop(
    state: DaemonHttpState,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    let Some(db) = state.async_db.get().cloned() else {
        return;
    };
    let mut ticker = interval(RECOVERY_INTERVAL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
            _ = ticker.tick() => Box::pin(recover_pending_dispatches(&state, &db)).await,
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "recovery drains preparation and worker intent queues while preserving per-claim errors"
)]
async fn recover_pending_dispatches(state: &DaemonHttpState, db: &AsyncDaemonDb) {
    for _ in 0..MAX_RECOVERIES_PER_TICK {
        let preparation = match db.claim_next_task_board_dispatch_preparation().await {
            Ok(Some(claim)) => claim,
            Ok(None) => break,
            Err(error) => {
                warn!(%error, "task board dispatch preparation claim failed");
                break;
            }
        };
        if let Err((_, error)) = prepare_claimed_task_board_dispatch(db, &preparation).await
            && let Err(release_error) = db
                .release_task_board_dispatch_preparation(&preparation, &error.to_string())
                .await
        {
            warn!(%release_error, "task board dispatch preparation release failed");
        }
    }
    for _ in 0..MAX_RECOVERIES_PER_TICK {
        let claim = match db.claim_next_task_board_dispatch().await {
            Ok(Some(claim)) => claim,
            Ok(None) => break,
            Err(error) => {
                warn!(%error, "task board dispatch recovery claim failed");
                break;
            }
        };
        finish_claim(state, db, claim).await;
    }
    if let Err(error) =
        Box::pin(
            super::super::task_board_read_only_coordinator::
                reconcile_task_board_read_only_workflows(state, db),
        )
        .await
    {
        warn!(%error, "read-only workflow recovery failed");
    }
}

async fn finish_claim(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    mut claim: ClaimedTaskBoardDispatch,
) {
    let _heartbeat =
        maintain_task_board_dispatch_claim(db.clone(), &claim.intent_id, &claim.claim_token);
    if let Some(reason) = compensation_reason(&claim.action) {
        finish_compensating_claim(state, db, &claim, reason).await;
        return;
    }
    if let Err(error) = settle_claimed_task_board_worker(state, db, &mut claim).await {
        warn!(
            board_item_id = %claim.applied.board_item_id,
            %error,
            "task board worker recovery settlement failed; leaving durable state for recovery"
        );
    }
}

fn compensation_reason(action: &TaskBoardDispatchClaimAction) -> Option<&str> {
    match action {
        TaskBoardDispatchClaimAction::Start | TaskBoardDispatchClaimAction::Recover => None,
        TaskBoardDispatchClaimAction::Compensate { reason } => Some(reason.as_str()),
    }
}

async fn finish_compensating_claim(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
    reason: &str,
) {
    if let Err(error) = resume_worker_compensation(
        state,
        db,
        &claim.applied,
        &claim.intent_id,
        &claim.claim_token,
    )
    .await
    {
        warn!(
            board_item_id = %claim.applied.board_item_id,
            %error,
            "task board worker compensation retry failed; leaving durable compensation pending"
        );
        return;
    }
    if let Err(error) = db
        .finalize_task_board_dispatch_compensation(
            &claim.intent_id,
            &claim.claim_token,
            &managed_worker_id(&claim.applied, &claim.intent_id),
            reason,
        )
        .await
    {
        warn!(
            board_item_id = %claim.applied.board_item_id,
            %error,
            "task board worker compensation rollback failed; leaving durable compensation pending"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::{TaskBoardDispatchClaimAction, compensation_reason};

    #[test]
    fn recovered_compensation_routes_around_worker_start() {
        let action = TaskBoardDispatchClaimAction::Compensate {
            reason: "worker stop required".to_string(),
        };

        assert_eq!(compensation_reason(&action), Some("worker stop required"));
        assert_eq!(
            compensation_reason(&TaskBoardDispatchClaimAction::Start),
            None
        );
        assert_eq!(
            compensation_reason(&TaskBoardDispatchClaimAction::Recover),
            None
        );
    }
}
