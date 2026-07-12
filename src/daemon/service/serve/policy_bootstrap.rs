//! Policy-storage boot wiring for `serve`.
//!
//! Seeds the database policy workspace and installs decision recording.

use tokio::sync::mpsc;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::policy_graph::{
    PolicyCanvasWorkspace, RecordedPolicyDecision, install_decision_sink,
};

/// Wire policy storage at daemon boot and seed the database-backed workspace.
///
/// # Errors
/// Returns `CliError` when the database read/seed fails.
pub(super) async fn bootstrap_policy_storage(async_db: &AsyncDaemonDb) -> Result<(), CliError> {
    install_decision_recording(async_db);
    ensure_policy_workspace(async_db).await?;
    Ok(())
}

/// Retention cap for the recorded-decision feed. The feed is a rolling window
/// for replay, so the table is bounded well above the largest replay request
/// (`MAX_REPLAY_LIMIT` = 500) and trimmed back to this size as new records land.
const POLICY_DECISION_RETENTION: usize = 2_000;

/// Prune cadence: trim the feed once this many records have been drained, so the
/// background writer amortizes the delete instead of running it on every insert.
const POLICY_DECISION_PRUNE_INTERVAL: u32 = 256;

/// Wire the enforced-decision recording feed.
///
/// A background drain task owns a cloned async handle and persists each record
/// the synchronous gate emits, so the gating hot path only enqueues onto an
/// unbounded channel and never blocks on the database. Recording failures are
/// logged, never propagated, so a write fault can never block a real mutation.
///
/// The drain also bounds the feed: it trims once at boot (clearing any backlog
/// from before retention existed) and again every `POLICY_DECISION_PRUNE_INTERVAL`
/// records, keeping the table near `POLICY_DECISION_RETENTION` rows.
fn install_decision_recording(async_db: &AsyncDaemonDb) {
    let db = async_db.clone();
    let (sender, mut receiver) = mpsc::unbounded_channel::<RecordedPolicyDecision>();
    tokio::spawn(async move {
        prune_recorded_decisions(&db).await;
        let mut since_prune = 0_u32;
        while let Some(decision) = receiver.recv().await {
            if let Err(error) = db.record_policy_decision_row(&decision).await {
                tracing::warn!(%error, decision_id = %decision.id, "failed to record policy decision");
            }
            since_prune += 1;
            if since_prune >= POLICY_DECISION_PRUNE_INTERVAL {
                since_prune = 0;
                prune_recorded_decisions(&db).await;
            }
        }
    });
    install_decision_sink(Box::new(move |decision| {
        let _ = sender.send(decision);
    }));
}

/// Trim the recorded-decision feed back to `POLICY_DECISION_RETENTION` rows,
/// logging and swallowing any failure so retention never disturbs recording.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
async fn prune_recorded_decisions(db: &AsyncDaemonDb) {
    if let Err(error) = db.prune_policy_decisions(POLICY_DECISION_RETENTION).await {
        tracing::warn!(%error, "failed to prune policy decisions");
    }
}

/// Persist a default workspace when the database is still empty.
async fn ensure_policy_workspace(async_db: &AsyncDaemonDb) -> Result<(), CliError> {
    if async_db.load_policy_workspace().await?.is_none() {
        let seeded = PolicyCanvasWorkspace::seeded();
        async_db.replace_policy_workspace(&seeded).await?;
    }
    Ok(())
}
