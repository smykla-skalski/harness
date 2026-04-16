use sqlx::query_scalar;
use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn connect_reads_current_schema_version() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    assert_eq!(
        sync_db.schema_version().expect("sync schema version"),
        SCHEMA_VERSION
    );

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(applied_migration_versions(&async_db).await, vec![1, 2]);
}

#[tokio::test]
async fn connect_bootstraps_empty_database_with_sqlx_migrations() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(
        async_db.health_counts().await.expect("async health counts"),
        (0, 0, 0)
    );
    assert_eq!(applied_migration_versions(&async_db).await, vec![1, 2]);
}

#[tokio::test]
async fn connect_migrates_legacy_schema_before_opening_pool() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute_batch(
        "CREATE TABLE schema_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;
            INSERT INTO schema_meta (key, value) VALUES ('version', '6');
            CREATE TABLE projects (
                project_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                project_dir TEXT,
                repository_root TEXT,
                checkout_id TEXT NOT NULL,
                checkout_name TEXT NOT NULL,
                context_root TEXT NOT NULL UNIQUE,
                is_worktree INTEGER NOT NULL DEFAULT 0,
                worktree_name TEXT,
                origin_json TEXT,
                discovered_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE sessions (
                session_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES projects(project_id),
                schema_version INTEGER NOT NULL,
                state_version INTEGER NOT NULL DEFAULT 0,
                title TEXT NOT NULL DEFAULT '',
                context TEXT NOT NULL,
                status TEXT NOT NULL,
                leader_id TEXT,
                observe_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_activity_at TEXT,
                archived_at TEXT,
                pending_leader_transfer TEXT,
                metrics_json TEXT NOT NULL DEFAULT '{}',
                state_json TEXT NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 1
            ) WITHOUT ROWID;
            INSERT INTO projects (
                project_id, name, project_dir, repository_root, checkout_id,
                checkout_name, context_root, is_worktree, worktree_name,
                origin_json, discovered_at, updated_at
            ) VALUES (
                'project-1', 'harness', '/tmp/harness', '/tmp/harness', 'checkout',
                'Repository', '/tmp/data/project-1', 0, NULL,
                NULL, '2026-04-14T10:00:00Z', '2026-04-14T10:00:00Z'
            );
            INSERT INTO sessions (
                session_id, project_id, schema_version, state_version, title, context,
                status, leader_id, observe_id, created_at, updated_at, last_activity_at,
                archived_at, pending_leader_transfer, metrics_json, state_json, is_active
            ) VALUES (
                'sess-test-1', 'project-1', 3, 1, 'title', 'context',
                'active', 'claude-leader', NULL, '2026-04-14T10:00:00Z',
                '2026-04-14T10:00:00Z', NULL, NULL, NULL, '{}', '{}', 1
            );",
    )
    .expect("seed v6 schema");

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(
        async_db.health_counts().await.expect("async health counts"),
        (1, 0, 1)
    );
    assert_eq!(applied_migration_versions(&async_db).await, vec![1, 2]);
}

#[tokio::test]
async fn connect_preserves_existing_db_when_baseline_checksum_drifted() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    drop(sync_db);

    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS _sqlx_migrations (
                version BIGINT PRIMARY KEY,
                description TEXT NOT NULL,
                installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                success BOOLEAN NOT NULL,
                checksum BLOB NOT NULL,
                execution_time BIGINT NOT NULL
            );",
    )
    .expect("create sqlx ledger");
    conn.execute(
        "INSERT INTO _sqlx_migrations (
                version, description, success, checksum, execution_time
            ) VALUES (?1, ?2, 1, ?3, 0)",
        rusqlite::params![1_i64, "daemon v7 baseline", vec![0_u8; 48]],
    )
    .expect("seed mismatched baseline checksum");
    drop(conn);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db with existing checksum drift");
    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(applied_migration_versions(&async_db).await, vec![1, 2]);
}

#[test]
fn cache_startup_diagnostics_persists_async_cache_entries() {
    let data_home = tempdir().expect("tempdir");
    let home = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(data_home.path().to_str().expect("utf8 path")),
            ),
            ("HOME", Some(home.path().to_str().expect("utf8 path"))),
            ("CLAUDE_SESSION_ID", Some("async-diagnostics-cache-test")),
        ],
        || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async {
                let db_path = data_home.path().join("harness.db");
                let async_db = AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db");

                async_db
                    .cache_startup_diagnostics()
                    .await
                    .expect("cache startup diagnostics");

                assert!(
                    async_db
                        .load_cached_launch_agent_status()
                        .await
                        .expect("load cached launch agent")
                        .is_some()
                );
                assert!(
                    async_db
                        .load_cached_workspace_diagnostics()
                        .await
                        .expect("load cached workspace diagnostics")
                        .is_some()
                );
            });
        },
    );
}

async fn applied_migration_versions(db: &AsyncDaemonDb) -> Vec<i64> {
    query_scalar::<_, i64>("SELECT version FROM _sqlx_migrations ORDER BY version")
        .fetch_all(db.pool())
        .await
        .expect("query applied migrations")
}
