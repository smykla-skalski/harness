use sha2::{Digest as _, Sha384};
use sqlx::query_scalar;
use tempfile::tempdir;

use super::*;

const ORIGINAL_V34_CHECKSUM: &str = "8FCF9F433E6EAC486506DB75C5618B21D7F8D9AD7AEBA2CB32ED7B4AF60042A3B9A36C8030A7FDB646224CC69FAB4D83";

#[tokio::test]
async fn connect_upgrades_applied_original_v34_migration() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open current sync daemon db");
    restore_original_v34_upgrade_shape(&sync_db);
    drop(sync_db);

    let conn = Connection::open(&db_path).expect("open sqlite");
    conn.execute(
        "INSERT INTO policy_workspace (
            singleton, active_canvas_id, workspace_schema_version, updated_at
         ) VALUES (1, 'canvas-1', 1, '2026-07-14T10:00:00Z')",
        [],
    )
    .expect("seed original v34 workspace");
    conn.execute(
        "UPDATE policy_workspace SET spawn_requires_live_policy = 0",
        [],
    )
    .expect("restore original v34 spawn default");
    conn.execute(
        "UPDATE schema_meta SET value = '34' WHERE key = 'version'",
        [],
    )
    .expect("stamp original v34 schema");
    conn.execute_batch(
        "CREATE TABLE _sqlx_migrations (
            version BIGINT PRIMARY KEY,
            description TEXT NOT NULL,
            installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            success BOOLEAN NOT NULL,
            checksum BLOB NOT NULL,
            execution_time BIGINT NOT NULL
        );",
    )
    .expect("create migration ledger");
    conn.execute(
        "INSERT INTO _sqlx_migrations (
            version, description, success, checksum, execution_time
         ) VALUES (?1, ?2, 1, ?3, 0)",
        rusqlite::params![
            28_i64,
            "daemon v34 spawn policy",
            hex::decode(ORIGINAL_V34_CHECKSUM).expect("decode v34 checksum")
        ],
    )
    .expect("record original v34 migration");
    drop(conn);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("upgrade applied original v34 database");

    assert_eq!(
        async_db
            .schema_version()
            .await
            .expect("async schema version"),
        SCHEMA_VERSION
    );
    assert_eq!(
        applied_migration_versions(&async_db).await,
        (1..=38).collect::<Vec<i64>>()
    );
    let requires_live = query_scalar::<_, bool>(
        "SELECT spawn_requires_live_policy FROM policy_workspace WHERE singleton = 1",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("read migrated spawn switch");
    assert!(requires_live, "v35 upgrade must fail closed");
    let has_grant_tracking = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM pragma_table_info('task_board_dispatch_intents')
         WHERE name = 'consumed_approval_grant_id'",
    )
    .fetch_one(async_db.pool())
    .await
    .expect("inspect migrated dispatch schema");
    assert_eq!(has_grant_tracking, 1);
}

fn restore_original_v34_upgrade_shape(db: &DaemonDb) {
    // This compatibility test starts from the current sync snapshot so it can
    // seed one historical SQLx ledger row. A version stamp alone is not a
    // historical schema: strict v43 correctly rejects current remote tables
    // paired with a partially downgraded dispatch table. Restore the remote
    // and dispatch lineage to shapes the v35 -> v43 chain can actually emit,
    // then remove the v35 and v39 effects exercised by that chain.
    crate::daemon::db::schema_v43::restore_legacy_v40_for_test(db);
    db.connection()
        .execute_batch(
            "DROP TABLE task_board_dispatch_admission_ledger;
             DROP TABLE task_board_dispatch_admission_decisions;
             DROP INDEX task_board_dispatch_intents_admission_identity;
             ALTER TABLE task_board_dispatch_intents DROP COLUMN compensation_pending;
             ALTER TABLE task_board_items DROP COLUMN estimated_cost_microusd;
             ALTER TABLE task_board_items DROP COLUMN estimated_tokens;
             ALTER TABLE task_board_dispatch_intents DROP COLUMN consumed_approval_grant_id;",
        )
        .expect("restore original v34 admission and dispatch effects");
}

const SHIPPED_MIGRATION_CHECKSUMS: &[(&str, &str)] = &[
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
    ("0028_daemon_v34_spawn_policy.sql", ORIGINAL_V34_CHECKSUM),
    (
        "0029_daemon_v35_dispatch_grant_tracking.sql",
        "1D392CEFB28441A88B9ADBC5E3D6A300D66804A874C96432858283BFDC7FA7BB4405C5F024DE500B78343D55A1859A80",
    ),
    (
        "0030_daemon_v36_task_board_automation.sql",
        "10587AC9F726A588A6B57955793ED4BA4AE8EE53CE787411B7B2E7CE967F14C9F00A740837BF73828A345756C068237B",
    ),
    (
        "0031_daemon_v37_task_board_backlog.sql",
        "D55E7ECAA6D350295FB1955CFD42592FAB8026205AEA7E714330E1DD293867F4150FDC52BE3169CE7B3037A569C0AB89",
    ),
    (
        "0032_daemon_v38_task_board_external_create_intents.sql",
        "C7D2FB56584DD8D1DE324D944A13B1B5F73F1DE76A78A36E12F9C2CB4485E6B437AA03C5214D8B1DF13743276318FB3E",
    ),
    (
        "0033_daemon_v39_task_board_policy_admission.sql",
        "91742D2F0BCDF2830FB7720DFE53675C83DAD8B9575B653E0A558A31C6C3C11A60A687CE621E20B069040ACDD351294D",
    ),
    (
        "0034_daemon_v40_task_board_reconciliation_cursors.sql",
        "FC06379A2C8BB18CD0EB3C6D20A5F83F6E0DA271B47891BB1BE1F3E7ADF9A431C664C6527D2BB7348CECDAA1BB96D4B0",
    ),
    (
        "0037_daemon_v43_task_board_remote_execution.sql",
        "F125288DF483846801C2E50E4B5313747ED4817A91E87675B1040CE2D661806957E44B8F3953530077670F0B2DCF4083",
    ),
    (
        "0038_daemon_v44_task_board_lane_order.sql",
        "4DEA33ABAE80ACA81B3644E575B82D940F04382703BD81FE3BFE8E413F95D4F637DBB827A02936E9FED7C87F4B7F3F6E",
    ),
];

#[test]
fn shipped_daemon_async_migration_checksums_remain_stable() {
    let migrations_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/daemon/db/migrations");

    for &(filename, expected_checksum) in SHIPPED_MIGRATION_CHECKSUMS {
        let bytes = std::fs::read(migrations_dir.join(filename)).expect("read migration");
        let actual_checksum = hex::encode_upper(Sha384::digest(bytes));
        assert_eq!(
            actual_checksum, expected_checksum,
            "shipped SQLx migration {filename} changed; add a new migration instead"
        );
    }
}

async fn applied_migration_versions(db: &AsyncDaemonDb) -> Vec<i64> {
    query_scalar::<_, i64>("SELECT version FROM _sqlx_migrations ORDER BY version")
        .fetch_all(db.pool())
        .await
        .expect("query applied migrations")
}
