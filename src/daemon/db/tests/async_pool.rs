use serde_json::json;
use sha2::{Digest as _, Sha384};
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
    assert_eq!(
        applied_migration_versions(&async_db).await,
        (1..=22).collect::<Vec<i64>>()
    );
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
    assert_eq!(
        applied_migration_versions(&async_db).await,
        (1..=22).collect::<Vec<i64>>()
    );
    let policy_workspace_columns =
        query_scalar::<_, String>("SELECT name FROM pragma_table_info('policy_workspace')")
            .fetch_all(async_db.pool())
            .await
            .expect("query policy workspace columns");
    assert!(policy_workspace_columns.contains(&"global_policy_enforcement_enabled".to_string()));
    assert!(!policy_workspace_columns.contains(&"enforcement_snapshot_json".to_string()));
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
                'main', '/tmp/data/project-1', 0, NULL,
                NULL, '2026-04-14T10:00:00Z', '2026-04-14T10:00:00Z'
            );
            INSERT INTO sessions (
                session_id, project_id, schema_version, state_version, title, context,
                status, leader_id, observe_id, created_at, updated_at, last_activity_at,
                archived_at, pending_leader_transfer, metrics_json, state_json, is_active
            ) VALUES (
                'f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4', 'project-1', 3, 1, 'title', 'context',
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
    assert_eq!(
        applied_migration_versions(&async_db).await,
        (1..=22).collect::<Vec<i64>>()
    );
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
    assert_eq!(
        applied_migration_versions(&async_db).await,
        (1..=22).collect::<Vec<i64>>()
    );
}

#[tokio::test]
async fn connect_accepts_v22_db_with_recorded_policy_snapshot_migration() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    drop(sync_db);

    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute(
        "ALTER TABLE policy_workspace ADD COLUMN enforcement_snapshot_json TEXT",
        [],
    )
    .expect("restore historical policy snapshot column");
    conn.execute(
        "UPDATE schema_meta SET value = '22' WHERE key = 'version'",
        [],
    )
    .expect("stamp v22 schema");
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
        rusqlite::params![
            10_i64,
            "daemon v16 policy enforcement snapshot",
            hex::decode("AD3FED5DD4D1E51BFD7462F1CC56185635E4EACDEE1CCA3332688CED4867985A88883E18495BB4232C12F6DDB125FF46")
                .expect("decode v16 checksum")
        ],
    )
    .expect("seed historical v16 sqlx ledger row");
    drop(conn);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db with recorded policy snapshot migration");
    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(
        applied_migration_versions(&async_db).await,
        (1..=22).collect::<Vec<i64>>()
    );
    let policy_workspace_columns =
        query_scalar::<_, String>("SELECT name FROM pragma_table_info('policy_workspace')")
            .fetch_all(async_db.pool())
            .await
            .expect("query policy workspace columns");
    assert!(!policy_workspace_columns.contains(&"enforcement_snapshot_json".to_string()));
}

#[tokio::test]
async fn connect_seeds_v18_sqlx_ledger_when_sync_schema_already_applied() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    assert_eq!(
        sync_db.schema_version().expect("sync schema version"),
        SCHEMA_VERSION
    );
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db with existing v18 schema");
    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(
        applied_migration_versions(&async_db).await,
        (1..=22).collect::<Vec<i64>>()
    );
}

#[tokio::test]
async fn connect_repairs_v8_active_sessions_without_leader_before_opening_pool() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let session_id = {
        let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
        let project = sample_project();
        sync_db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        sync_db
            .sync_session(&project.project_id, &state)
            .expect("sync session");
        sync_db
            .conn
            .execute(
                "UPDATE sessions
                 SET status = 'active',
                     leader_id = NULL,
                     metrics_json = ?1,
                     state_json = ?2,
                     is_active = 1
                 WHERE session_id = ?3",
                rusqlite::params![
                    json!({
                        "agent_count": 0,
                        "active_agent_count": 0,
                        "idle_agent_count": 0,
                        "open_task_count": 0,
                        "in_progress_task_count": 0,
                        "blocked_task_count": 0,
                        "completed_task_count": 0
                    })
                    .to_string(),
                    json!({
                        "schema_version": 6,
                        "state_version": 1,
                        "session_id": state.session_id,
                        "title": state.title,
                        "context": state.context,
                        "status": "active",
                        "created_at": state.created_at,
                        "updated_at": state.updated_at,
                        "agents": {},
                        "tasks": {},
                        "leader_id": null,
                        "archived_at": null,
                        "last_activity_at": state.last_activity_at,
                        "observe_id": state.observe_id,
                        "pending_leader_transfer": null,
                        "metrics": {
                            "agent_count": 0,
                            "active_agent_count": 0,
                            "idle_agent_count": 0,
                            "open_task_count": 0,
                            "in_progress_task_count": 0,
                            "blocked_task_count": 0,
                            "completed_task_count": 0
                        }
                    })
                    .to_string(),
                    state.session_id,
                ],
            )
            .expect("corrupt v8 row");
        sync_db
            .conn
            .execute(
                "UPDATE schema_meta SET value = '8' WHERE key = 'version'",
                [],
            )
            .expect("downgrade schema");
        state.session_id
    };

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
        applied_migration_versions(&async_db).await,
        (1..=22).collect::<Vec<i64>>()
    );
    drop(async_db);

    let sync_db = DaemonDb::open(&db_path).expect("reopen sync daemon db");
    let repaired = sync_db
        .load_session_state(&session_id)
        .expect("load repaired session")
        .expect("session present");
    assert_eq!(repaired.status, SessionStatus::LeaderlessDegraded);
    assert!(repaired.leader_id.is_none());
}

#[test]
fn shipped_daemon_async_migration_checksums_remain_stable() {
    let migrations = [
        (
            "0001_daemon_v7_baseline.sql",
            "6EEA02EDAA6DBAF2DC500FFC9969898E332A333F76036F9ECE6721D92B0F01C3D7F8CDEAADA20566C3241AAF8D73A7D8",
        ),
        (
            "0002_daemon_v8_backfill.sql",
            "D85A1C880A42852459041AA780F3F42FFE8C445E87FC4D06F5AA5E6AB23C519F692EDBA7FE1387EB8646B0AC7606619D",
        ),
        (
            "0003_daemon_v9_active_leader_repair.sql",
            "E53A3D7DDC9C3B17C71019BBEE586E2780A27CB75704201448CD87832920CC31EBF3A2D139216D7F080F959590FB1406",
        ),
        (
            "0004_daemon_v10_review_workflow.sql",
            "FD8F12D2B7B9074A8F395DC09E27952CF7F12000045076130075AFAC92006CC3771A48AC649FB319D36AE2178F40CB39",
        ),
        (
            "0005_daemon_v11_managed_agents.sql",
            "AB561ACA3E53AE4127071BE937192D3DE3845FA1E28F4AF6AE4C31D7C7AB952C9383F4596D5BB71A2EE80FBE951BC227",
        ),
        (
            "0006_daemon_v12_task_deletes.sql",
            "FEA610956DD4A93FB4DA23DAF451B2A1779CB6CC1D9F0EB7FA670EC4AF10EAD1E81ED684AA1269626A03C3194E9F82F6",
        ),
        (
            "0007_daemon_v13_codex_agents.sql",
            "5621B16005FDA58D501AEDEB24333D82668B4026750AACF9779DA2026387AE0ED052B0171ED115884B131411CFA204BA",
        ),
        (
            "0008_daemon_v14_policy_graph.sql",
            "61A23A7DB84C0CB0AAAB6A45A227A1652CBA841AE7FA9621DB49E1B8325B23B694AD81E42E0142FE1ACDEB3A6168970E",
        ),
        (
            "0009_daemon_v15_policy_canvas_identity.sql",
            "FE683A0EA0B11242EC49C7F698BD84C2EA3166EB47964FABAF5689487CE8C791954E1CCD07759139E5F1BE94913AD278",
        ),
        (
            "0010_daemon_v16_policy_enforcement_snapshot.sql",
            "AD3FED5DD4D1E51BFD7462F1CC56185635E4EACDEE1CCA3332688CED4867985A88883E18495BB4232C12F6DDB125FF46",
        ),
        (
            "0011_daemon_v17_audit_events.sql",
            "5ABCF35807711FF2E484FD7232E88B3FB40D72FB251A4565EF5B7CB473068C2B768CB12E9305096A63622193508F2AF2",
        ),
        (
            "0012_daemon_v18_review_screenshot_canvas.sql",
            "C73EB29CCD31FF44A696DC24BD110D69EF3A1263BF14AC808B8162105074E892B65DE94D0AD5FF8F7DCADDF5376F1839",
        ),
        (
            "0013_daemon_v19_manual_ocr_canvas.sql",
            "63D023C30B544086655F944FE7FA91BEE75D31FD784B4544F9855F173657EB2EEBD5AE4A95FC80DF8909B364EB96336D",
        ),
        (
            "0014_daemon_v20_policy_canvas_viewport.sql",
            "ED606394E81442888E63169C91B434A759BBB5C4955C7280224E67E4CC80924F5CB0125C34D31F6165AE852394F7EE1A",
        ),
        (
            "0015_daemon_v21_policy_node_layout_source.sql",
            "9414A044B453ADB1390BC5F0A77F57E6A8C180083FD79947F05093E9D8E4E0D87845B020D944CA296C0CCE7A40C88CA2",
        ),
        (
            "0016_daemon_v22_global_policy_enforcement.sql",
            "39A20F260F1D497B9EB1AD201B858EB7A8F821813ADD490653F7E78FD779CD68B19DD163BADE63F61E9C180F5E864C22",
        ),
        (
            "0017_daemon_v23_drop_policy_enforcement_snapshot.sql",
            "51CC1C253ED07B4482E6B7B2E91405CECDBE151AD36F87F86EA3698A581FA8A01456C1602659CE3E8B44422235B6B847",
        ),
    ];
    let migrations_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/daemon/db/migrations");

    for (filename, expected_checksum) in migrations {
        let bytes = std::fs::read(migrations_dir.join(filename)).expect("read migration");
        let actual_checksum = hex::encode_upper(Sha384::digest(bytes));
        assert_eq!(
            actual_checksum, expected_checksum,
            "shipped SQLx migration {filename} changed; add a new migration instead"
        );
    }
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
