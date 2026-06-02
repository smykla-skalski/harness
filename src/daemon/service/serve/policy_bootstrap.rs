//! Policy-storage boot wiring for `serve`.
//!
//! Installs the database-backed gating cold-read seam and warms the synchronous
//! gating cache from the durable workspace.

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::state;
use crate::errors::CliError;
use crate::task_board::default_board_root;
use crate::task_board::policy_graph::{
    PolicyCanvasWorkspace, PolicyGraph, install_gate_coldfill, store_gate_policy,
};

/// Wire policy storage at daemon boot: install the cold-read seam and warm the
/// gating cache from the database-backed workspace.
///
/// # Errors
/// Returns `CliError` when the database read/seed fails.
pub(super) async fn bootstrap_policy_storage(async_db: &AsyncDaemonDb) -> Result<(), CliError> {
    install_gate_coldfill(Box::new(sync_coldfill_active_document));
    warm_gate_cache(async_db).await?;
    Ok(())
}

/// Synchronous cold-read of the active canvas document straight from the
/// database. Installed as the gating seam so the lock-free hot path can fall
/// through without a tokio runtime. Any missing, draft, or dry-run policy
/// yields `None`; callers that mutate external state must fail closed.
fn sync_coldfill_active_document() -> Option<PolicyGraph> {
    let database = DaemonDb::open(&state::daemon_root().join("harness.db")).ok()?;
    let workspace = database.load_policy_workspace().ok().flatten()?;
    workspace
        .active_enforced_canvas()
        .map(|canvas| canvas.document.clone())
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
    store_gate_policy(
        &default_board_root(),
        workspace
            .active_enforced_canvas()
            .map(|canvas| canvas.document.clone()),
    );
    Ok(())
}
