//! Policy-storage boot wiring for `serve`.
//!
//! Installs the database-backed gating cold-read seam, performs the one-time
//! JSON-to-database import of legacy policy canvases, and warms the synchronous
//! gating cache from the durable workspace.

use std::fs;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::default_board_root;
use crate::task_board::policy_graph::{
    PolicyCanvasWorkspace, PolicyGraph, PolicyPipelineSimulationResult, install_gate_coldfill,
    store_gate_policy,
};

const CANVAS_WORKSPACE_FILE: &str = "policy-canvases-v1.json";
const LEGACY_PIPELINE_FILE: &str = "policy-pipeline-v2.json";
const LEGACY_SIMULATION_FILE: &str = "policy-pipeline-v2-simulation.json";
const IMPORTED_SUFFIX: &str = ".imported.bak";

/// Wire policy storage at daemon boot: install the cold-read seam, import any
/// legacy JSON files into the database once, and warm the gating cache.
///
/// # Errors
/// Returns `CliError` when the database read/seed or a JSON import fails.
pub(super) async fn bootstrap_policy_storage(async_db: &AsyncDaemonDb) -> Result<(), CliError> {
    install_gate_coldfill(Box::new(sync_coldfill_active_document));
    import_legacy_json_if_needed(async_db).await?;
    warm_gate_cache(async_db).await?;
    Ok(())
}

/// Synchronous cold-read of the active canvas document straight from the
/// database. Installed as the gating seam so the lock-free hot path can fall
/// through without a tokio runtime. Any failure yields `None`, falling open to
/// the built-in gate.
fn sync_coldfill_active_document() -> Option<PolicyGraph> {
    let database = DaemonDb::open(&state::daemon_root().join("harness.db")).ok()?;
    let workspace = database.load_policy_workspace().ok().flatten()?;
    workspace
        .active_canvas()
        .map(|canvas| canvas.document.clone())
}

/// Import the legacy JSON canvas files into the database exactly once, when the
/// database holds no workspace yet. The source files are renamed to
/// `*.imported.bak` so a subsequent boot does not re-import them.
async fn import_legacy_json_if_needed(async_db: &AsyncDaemonDb) -> Result<(), CliError> {
    if async_db.load_policy_workspace().await?.is_some() {
        return Ok(());
    }
    let root = default_board_root();
    if root.join(CANVAS_WORKSPACE_FILE).exists() {
        import_canvas_workspace(async_db, &root).await
    } else if root.join(LEGACY_PIPELINE_FILE).exists() {
        import_legacy_pipeline(async_db, &root).await
    } else {
        Ok(())
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::info! macro expands into a chain clippy reads as branchy"
)]
async fn import_canvas_workspace(async_db: &AsyncDaemonDb, root: &Path) -> Result<(), CliError> {
    let path = root.join(CANVAS_WORKSPACE_FILE);
    let workspace: PolicyCanvasWorkspace = read_json(&path)?;
    async_db.replace_policy_workspace(&workspace).await?;
    rename_imported(&path)?;
    tracing::info!(
        target: "harness::daemon::startup",
        canvases = workspace.canvases.len(),
        "imported legacy policy canvas workspace into the database"
    );
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::info! macro expands into a chain clippy reads as branchy"
)]
async fn import_legacy_pipeline(async_db: &AsyncDaemonDb, root: &Path) -> Result<(), CliError> {
    let document_path = root.join(LEGACY_PIPELINE_FILE);
    let document: PolicyGraph = read_json(&document_path)?;
    let simulation_path = root.join(LEGACY_SIMULATION_FILE);
    let simulation = if simulation_path.exists() {
        Some(read_json::<PolicyPipelineSimulationResult>(
            &simulation_path,
        )?)
    } else {
        None
    };
    let workspace = PolicyCanvasWorkspace::from_legacy(document, simulation);
    async_db.replace_policy_workspace(&workspace).await?;
    rename_imported(&document_path)?;
    if simulation_path.exists() {
        rename_imported(&simulation_path)?;
    }
    tracing::info!(
        target: "harness::daemon::startup",
        "imported legacy single-pipeline policy document into the database"
    );
    Ok(())
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
            .active_canvas()
            .map(|canvas| canvas.document.clone()),
    );
    Ok(())
}

fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T, CliError> {
    let contents = fs::read_to_string(path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "read legacy policy file {}: {error}",
            path.display()
        )))
    })?;
    serde_json::from_str(&contents).map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "parse legacy policy file {}: {error}",
            path.display()
        )))
    })
}

fn rename_imported(path: &Path) -> Result<(), CliError> {
    let backup = imported_backup_path(path);
    fs::rename(path, &backup).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "rename imported policy file {}: {error}",
            path.display()
        )))
    })
}

fn imported_backup_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(IMPORTED_SUFFIX);
    path.with_file_name(name)
}
