//! Policy-storage boot wiring for `serve`.
//!
//! Installs the database-backed gating cold-read seam and warms the synchronous
//! gating cache from the durable workspace.

use tokio::sync::mpsc;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::state;
use crate::errors::CliError;
use crate::task_board::default_board_root;
use crate::task_board::policy_graph::{
    CachedGatePolicy, PolicyCanvasWorkspace, PolicyGraph, RecordedPolicyDecision,
    install_decision_sink, install_gate_coldfill, store_gate_policy_entry,
};

/// Wire policy storage at daemon boot: install the cold-read seam and warm the
/// gating cache from the database-backed workspace.
///
/// # Errors
/// Returns `CliError` when the database read/seed fails.
pub(super) async fn bootstrap_policy_storage(async_db: &AsyncDaemonDb) -> Result<(), CliError> {
    install_gate_coldfill(Box::new(sync_coldfill_active_document));
    install_decision_recording(async_db);
    warm_gate_cache(async_db).await?;
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

/// Synchronous cold-read of the active canvas document straight from the
/// database. Installed as the gating seam so the lock-free hot path can fall
/// through without a tokio runtime. Any missing, draft, or dry-run policy
/// yields `None`; callers that mutate external state must fail closed.
fn sync_coldfill_active_document() -> Option<PolicyGraph> {
    let database = DaemonDb::open(&state::daemon_root().join("harness.db")).ok()?;
    let workspace = database.load_policy_workspace().ok().flatten()?;
    workspace.active_live_document().cloned()
}

/// Warm the synchronous gating cache from the durable workspace, seeding and
/// persisting a default workspace when the database is still empty.
async fn warm_gate_cache(async_db: &AsyncDaemonDb) -> Result<(), CliError> {
    let workspace = if let Some(workspace) = async_db.load_policy_workspace().await? {
        workspace
    } else {
        let seeded = PolicyCanvasWorkspace::seeded();
        async_db.replace_policy_workspace(&seeded).await?;
        seeded
    };
    store_gate_policy_entry(
        &default_board_root(),
        workspace.active_live_canvas().map(|(canvas, document)| {
            CachedGatePolicy::for_canvas(canvas.id.clone(), document.clone())
        }),
    );
    Ok(())
}
