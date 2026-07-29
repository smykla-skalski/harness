use super::*;
use tempfile::tempdir;

fn install_agent_delete_audit(connection: &rusqlite::Connection) {
    connection
        .execute_batch(
            "CREATE TABLE agent_delete_audit (
                delete_count INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO agent_delete_audit (delete_count) VALUES (0);
            CREATE TRIGGER audit_agent_delete
            AFTER DELETE ON agents
            BEGIN
                UPDATE agent_delete_audit
                SET delete_count = delete_count + 1;
            END;",
        )
        .expect("install agent delete audit");
}

fn recorded_agent_deletes(connection: &rusqlite::Connection) -> i64 {
    connection
        .query_row("SELECT delete_count FROM agent_delete_audit", [], |row| {
            row.get(0)
        })
        .expect("read agent delete audit")
}

#[test]
fn sync_session_resave_keeps_existing_agent_rows() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("initial sync");
    install_agent_delete_audit(&db.conn);

    db.save_session_state(&project.project_id, &state)
        .expect("resave session state");

    assert_eq!(recorded_agent_deletes(&db.conn), 0);
}

#[tokio::test]
async fn async_session_resave_keeps_existing_agent_rows() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync db");
    let project = sample_project();
    sync_db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    sync_db
        .sync_session(&project.project_id, &state)
        .expect("initial sync");
    install_agent_delete_audit(&sync_db.conn);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async db");
    async_db
        .save_session_state(&project.project_id, &state)
        .await
        .expect("resave session state");

    assert_eq!(recorded_agent_deletes(&sync_db.conn), 0);
}
