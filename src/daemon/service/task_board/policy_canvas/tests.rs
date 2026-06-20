use tempfile::{TempDir, tempdir};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::TaskBoardPolicyPipelinePromoteRequest;
use crate::task_board::policy_graph::{PolicyCanvasWorkspace, apply_set_global_enforcement};

use super::promote_task_board_policy_pipeline;

async fn connect() -> (TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect async daemon db");
    (dir, db)
}

#[tokio::test]
async fn legacy_promote_alias_enables_global_enforcement() {
    let (_dir, db) = connect().await;
    let mut workspace = PolicyCanvasWorkspace::seeded();
    apply_set_global_enforcement(&mut workspace, false);
    let revision = workspace
        .active_canvas()
        .expect("active canvas")
        .document
        .revision;
    db.replace_policy_workspace(&workspace)
        .await
        .expect("seed workspace");

    let response = promote_task_board_policy_pipeline(
        &db,
        &TaskBoardPolicyPipelinePromoteRequest {
            revision,
            actor: None,
            canvas_id: None,
        },
    )
    .await
    .expect("legacy promote");

    let loaded = db
        .load_policy_workspace()
        .await
        .expect("load")
        .expect("workspace");
    assert_eq!(response.document.revision, revision);
    assert!(loaded.global_policy_enforcement_enabled);
    assert_eq!(
        loaded.active_live_document().expect("live document").revision,
        revision,
    );
}
