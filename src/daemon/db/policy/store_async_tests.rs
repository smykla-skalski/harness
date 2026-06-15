use super::*;
use crate::errors::CliErrorKind;
use crate::task_board::policy_graph::{
    PolicyCanvasEnforcementSnapshot, PolicyGraphMode, apply_duplicate,
};
use tempfile::{TempDir, tempdir};

async fn connect() -> (TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect async daemon db");
    (dir, db)
}

#[tokio::test]
async fn load_unseeded_workspace_returns_none() {
    let (_dir, db) = connect().await;
    assert!(db.load_policy_workspace().await.expect("load").is_none());
}

#[tokio::test]
async fn workspace_round_trips_through_database() {
    let (_dir, db) = connect().await;
    let workspace = PolicyCanvasWorkspace::seeded();
    db.replace_policy_workspace(&workspace)
        .await
        .expect("replace");
    let loaded = db
        .load_policy_workspace()
        .await
        .expect("load")
        .expect("present");
    assert_eq!(loaded, workspace);
}

#[tokio::test]
async fn legacy_enforcement_snapshot_loads_as_disabled_global_gate() {
    let (_dir, db) = connect().await;
    let mut workspace = PolicyCanvasWorkspace::seeded();
    workspace.canvases[0].document.mode = PolicyGraphMode::Enforced;
    workspace.canvases[1].document.mode = PolicyGraphMode::DryRun;
    db.replace_policy_workspace(&workspace)
        .await
        .expect("replace");

    let snapshot = PolicyCanvasEnforcementSnapshot {
        active_canvas_id: workspace.active_canvas_id.clone(),
        canvases: workspace.canvases.clone(),
    };
    let snapshot_json = serde_json::to_string(&snapshot).expect("serialize snapshot");
    query("UPDATE policy_canvases SET mode = 'draft'")
        .execute(db.pool())
        .await
        .expect("simulate legacy disabled canvases");
    query(
        "UPDATE policy_workspace
         SET enforcement_snapshot_json = ?1,
             global_policy_enforcement_enabled = 1",
    )
    .bind(snapshot_json)
    .execute(db.pool())
    .await
    .expect("simulate legacy snapshot state");

    let loaded = db
        .load_policy_workspace()
        .await
        .expect("load")
        .expect("present");

    assert!(!loaded.global_policy_enforcement_enabled);
    assert_eq!(loaded.active_canvas_id, workspace.active_canvas_id);
    assert_eq!(loaded.canvases, workspace.canvases);
    assert!(loaded.enforcement_snapshot.is_none());
}

#[tokio::test]
async fn update_persists_mutation_atomically() {
    let (_dir, db) = connect().await;
    db.replace_policy_workspace(&PolicyCanvasWorkspace::seeded())
        .await
        .expect("seed");
    let (_, renamed) = db
        .update_policy_workspace(|workspace| {
            let canvas = workspace.canvases.first_mut().expect("a canvas");
            canvas.title = "Renamed".to_string();
            Ok(canvas.id.clone())
        })
        .await
        .expect("update");
    let loaded = db
        .load_policy_workspace()
        .await
        .expect("load")
        .expect("present");
    let canvas = loaded
        .canvases
        .iter()
        .find(|canvas| canvas.id == renamed)
        .expect("renamed");
    assert_eq!(canvas.title, "Renamed");
}

#[tokio::test]
async fn update_rolls_back_when_closure_rejects() {
    let (_dir, db) = connect().await;
    db.replace_policy_workspace(&PolicyCanvasWorkspace::seeded())
        .await
        .expect("seed");
    let before = db
        .load_policy_workspace()
        .await
        .expect("load")
        .expect("present");
    let outcome = db
        .update_policy_workspace(|workspace| -> Result<(), CliError> {
            workspace.canvases.clear();
            Err(CliErrorKind::invalid_transition("rejected").into())
        })
        .await;
    assert!(outcome.is_err());
    let after = db
        .load_policy_workspace()
        .await
        .expect("load")
        .expect("present");
    assert_eq!(after, before);
}

#[tokio::test]
async fn save_policy_canvas_draft_does_not_delete_unrelated_canvas_rows() {
    let (_dir, db) = connect().await;
    let mut workspace = PolicyCanvasWorkspace::seeded();
    let active_canvas_id = workspace.active_canvas_id.clone();
    let duplicate = apply_duplicate(&mut workspace, &active_canvas_id, Some("Experiment".into()))
        .expect("duplicate canvas");
    let duplicate = workspace
        .canvases
        .iter_mut()
        .find(|canvas| canvas.id == duplicate.id)
        .expect("duplicated canvas exists");
    duplicate.id = "unrelated-canvas-delete-sentinel".to_string();
    let inactive_before = duplicate.clone();
    db.replace_policy_workspace(&workspace)
        .await
        .expect("seed workspace");

    query(
        "CREATE TEMP TRIGGER reject_unrelated_policy_canvas_delete \
         BEFORE DELETE ON policy_canvases \
         WHEN OLD.canvas_id = 'unrelated-canvas-delete-sentinel' \
         BEGIN SELECT RAISE(ABORT, 'unrelated canvas delete'); END",
    )
    .execute(db.pool())
    .await
    .expect("install delete guard");

    let mut draft = workspace
        .canvas(&active_canvas_id)
        .expect("active canvas")
        .document
        .clone();
    draft.policy_trace_ids = vec!["row-scoped-save".to_string()];
    let saved = db
        .save_policy_canvas_draft(&active_canvas_id, draft, 0)
        .await
        .expect("save active canvas");

    assert!(saved.response.persisted);
    let loaded = db
        .load_policy_workspace()
        .await
        .expect("load")
        .expect("present");
    let inactive_after = loaded
        .canvas(&inactive_before.id)
        .expect("unrelated canvas should still exist");
    assert_eq!(inactive_after, &inactive_before);
}
