use std::time::Duration;

use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};
use tracing::warn;

use crate::daemon::db::{AsyncDaemonDb, ClaimedTaskBoardDispatch};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::service::task_board::prepare_claimed_task_board_dispatch;
use crate::daemon::task_board_managed_agents::start_worker_for_applied_task;

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
            _ = ticker.tick() => recover_pending_dispatches(&state, &db).await,
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
}

#[expect(
    clippy::cognitive_complexity,
    reason = "worker recovery must durably complete successful claims and roll back failed claims"
)]
async fn finish_claim(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    claim: ClaimedTaskBoardDispatch,
) {
    let result = start_worker_for_applied_task(state, &claim.applied, &claim.intent_id).await;
    match result {
        Ok(_) => {
            if let Err(error) = db
                .complete_task_board_dispatch(&claim.intent_id, &claim.claim_token)
                .await
            {
                warn!(board_item_id = %claim.applied.board_item_id, %error, "task board dispatch recovery completion failed");
            }
        }
        Err(error) => {
            if let Err(rollback_error) = db
                .fail_task_board_dispatch(&claim.intent_id, &claim.claim_token, &error.to_string())
                .await
            {
                warn!(board_item_id = %claim.applied.board_item_id, %rollback_error, "task board dispatch recovery rollback failed");
            }
        }
    }
}
