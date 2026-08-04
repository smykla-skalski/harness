use super::*;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::daemon::reviews_store::PolicyGraphQueries;
use crate::task_board::policy_graph::PolicyCanvasWorkspace;

async fn database() -> AsyncDaemonDb {
    let temp = tempfile::tempdir().expect("temp dir");
    let path = temp.keep().join("harness.db");
    AsyncDaemonDb::connect(&path).await.expect("open database")
}

#[tokio::test]
async fn disabled_policy_control_rejects_new_policy_runs() {
    let database = database().await;
    let mut workspace = PolicyCanvasWorkspace::seeded();
    workspace.global_policy_enforcement_enabled = false;
    database
        .replace_policy_workspace(&workspace)
        .await
        .expect("disable policy automation");

    let error = ensure_policy_automation_enabled(&database)
        .await
        .expect_err("disabled policy automation must reject new runs");

    assert!(error.to_string().contains("policy automation is disabled"));
}
