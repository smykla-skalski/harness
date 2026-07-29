use rusqlite::params;
use sqlx::{Executor, query};
use tempfile::tempdir;

use super::tests::{
    insert_strict_assignment, legacy_v40_fixture, legacy_v40_fixture_at, strict_request,
};
use super::*;
use crate::daemon::db::{
    AsyncDaemonDb, DaemonDb, TaskBoardRemoteHostTrustFence, TaskBoardRemoteLifecycleTrustSnapshot,
};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::task_board::TaskBoardExecutionHostConfig;

const REQUEST_SHA256: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const TRUST_SHA256: &str = "2222222222222222222222222222222222222222222222222222222222222222";

#[test]
fn fresh_schema_has_the_paired_controller_lifecycle_and_operation_tokens() {
    let db = DaemonDb::open_in_memory().expect("open fresh daemon db");
    let columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_assignments')
             WHERE name IN (
                 'controller_lifecycle_trust_json', 'controller_lifecycle_trust_sha256',
                 'controller_operation_kind', 'controller_operation_request_sha256',
                 'controller_operation_trust_sha256', 'controller_operation_fence_json',
                 'controller_operation_fence_sha256'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect controller operation token columns");
    assert_eq!(columns, 7);
}

#[test]
fn controller_operation_token_is_paired_bounded_and_canonical() {
    let db = strict_assignment_fixture();
    let fence = fixture_lifecycle_trust();
    let fence_json = fence.encoded().expect("encode lifecycle trust fixture");
    for update in [
        "controller_operation_kind = 'offer'",
        "controller_operation_kind = 'offer',
         controller_operation_request_sha256 = '1111111111111111111111111111111111111111111111111111111111111111'",
        "controller_operation_kind = 'monitor',
         controller_operation_request_sha256 = '1111111111111111111111111111111111111111111111111111111111111111',
         controller_operation_trust_sha256 = '2222222222222222222222222222222222222222222222222222222222222222'",
        "controller_operation_kind = 'status',
         controller_operation_request_sha256 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
         controller_operation_trust_sha256 = '2222222222222222222222222222222222222222222222222222222222222222'",
    ] {
        let error = db
            .connection()
            .execute(
                &format!(
                    "UPDATE task_board_remote_assignments SET {update}
                     WHERE assignment_id = 'assignment-a'"
                ),
                [],
            )
            .expect_err("invalid controller operation token must fail closed");
        assert!(error.to_string().contains("CHECK constraint failed"));
    }

    for kind in [
        "upload_source_bundle",
        "offer",
        "claim",
        "renew",
        "status",
        "cancel",
        "settle",
        "fetch_artifact",
    ] {
        db.connection()
            .execute(
                "UPDATE task_board_remote_assignments
                 SET controller_operation_kind = ?1,
                     controller_operation_request_sha256 = ?2,
                     controller_operation_trust_sha256 = ?3,
                     controller_operation_fence_json = ?4,
                     controller_operation_fence_sha256 = ?5
                 WHERE assignment_id = 'assignment-a'",
                params![
                    kind,
                    REQUEST_SHA256,
                    TRUST_SHA256,
                    fence_json,
                    fence.snapshot_sha256,
                ],
            )
            .expect("store canonical controller operation token");
    }
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET controller_operation_kind = 'observe_cleanup',
                 controller_operation_request_sha256 = ?1,
                 controller_operation_trust_sha256 = ?2,
                 controller_operation_fence_json = ?3,
                 controller_operation_fence_sha256 = ?4
             WHERE assignment_id = 'assignment-a'",
            params![
                REQUEST_SHA256,
                TRUST_SHA256,
                fence_json,
                fence.snapshot_sha256,
            ],
        )
        .expect("store canonical cleanup observation token");
}

#[test]
fn controller_operation_columns_are_part_of_the_strict_table_fingerprint() {
    let db = strict_assignment_fixture();
    db.connection()
        .execute_batch(
            "ALTER TABLE task_board_remote_assignments
             RENAME COLUMN controller_operation_kind TO stale_controller_operation_kind;",
        )
        .expect("corrupt current controller operation column identity");

    let error = run(db.connection()).expect_err("changed table identity must not be repaired");
    assert!(error.to_string().contains("refusing destructive repair"));
    let preserved: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM task_board_remote_assignments
             WHERE assignment_id = 'assignment-a'",
            [],
            |row| row.get(0),
        )
        .expect("strict repair must preserve the assignment row");
    assert_eq!(preserved, 1);
}

#[tokio::test]
async fn corrupt_controller_operation_tokens_fail_closed_after_reopen() {
    let temp = tempdir().expect("tempdir");
    for (suffix, diagnostic) in [
        (
            "partial",
            "controller operation trust evidence is incomplete",
        ),
        ("kind", "controller operation kind is invalid"),
        ("digest", "canonical lowercase SHA-256"),
        (
            "generation_digest",
            "lifecycle trust persistence is not canonical or digest-bound",
        ),
        (
            "fresh_successor",
            "operation lifecycle fence does not match its assignment generation",
        ),
        (
            "older_lifecycle_revision",
            "operation lifecycle fence does not match its assignment generation",
        ),
    ] {
        let path = temp.path().join(format!("{suffix}.db"));
        seed_corrupt_assignment(&path, suffix).await;
        let db = AsyncDaemonDb::connect(&path)
            .await
            .expect("reopen structurally valid v43 database");
        let error = db
            .task_board_remote_assignment("assignment-a")
            .await
            .expect_err("corrupt controller operation token must not decode");
        assert!(error.to_string().contains(diagnostic), "{suffix}: {error}");
    }
}

fn strict_assignment_fixture() -> DaemonDb {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let request = strict_request("assignment-a", "execution-a", 1, REQUEST_SHA256);
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert strict assignment");
    let lifecycle = fixture_lifecycle_trust();
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET controller_lifecycle_trust_json = ?1,
                 controller_lifecycle_trust_sha256 = ?2
             WHERE assignment_id = 'assignment-a'",
            params![
                lifecycle.encoded().expect("encode lifecycle trust fixture"),
                lifecycle.snapshot_sha256,
            ],
        )
        .expect("persist frozen lifecycle trust fixture");
    db
}

fn fixture_lifecycle_trust() -> TaskBoardRemoteLifecycleTrustSnapshot {
    fixture_lifecycle_trust_at(7, "instance-a", true)
}

fn fixture_lifecycle_trust_at(
    configuration_revision: u64,
    instance: &str,
    enabled: bool,
) -> TaskBoardRemoteLifecycleTrustSnapshot {
    TaskBoardRemoteLifecycleTrustSnapshot::capture(
        &TaskBoardRemoteHostTrustFence {
            config: TaskBoardExecutionHostConfig {
                host_id: "executor-a".into(),
                endpoint: "https://executor.example.test".into(),
                certificate_fingerprint: crate::task_board::remote_spki_pin::encode([0; 32]),
                credential_reference: "env://HARNESS_REMOTE_TOKEN".into(),
                enabled,
            },
            configuration_revision,
        },
        instance,
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    )
    .expect("capture lifecycle trust fixture")
}

async fn seed_corrupt_assignment(path: &std::path::Path, corruption: &str) {
    let db = insert_corruptible_assignment(path).await;
    let mut connection = db.pool().acquire().await.expect("acquire corrupt fixture");
    connection
        .execute("PRAGMA ignore_check_constraints = ON")
        .await
        .expect("allow corrupt-row fixture");
    let corrupt = match corruption {
        "partial" => query(
            "UPDATE task_board_remote_assignments
             SET controller_operation_kind = 'offer'
             WHERE assignment_id = 'assignment-a'",
        ),
        "kind" => query(
            "UPDATE task_board_remote_assignments
             SET controller_operation_kind = 'monitor',
                 controller_operation_request_sha256 =
                     '1111111111111111111111111111111111111111111111111111111111111111',
                 controller_operation_trust_sha256 =
                     '2222222222222222222222222222222222222222222222222222222222222222'
             WHERE assignment_id = 'assignment-a'",
        ),
        "digest" => query(
            "UPDATE task_board_remote_assignments
             SET controller_operation_kind = 'offer',
                 controller_operation_request_sha256 =
                     'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                 controller_operation_trust_sha256 =
                     '2222222222222222222222222222222222222222222222222222222222222222'
             WHERE assignment_id = 'assignment-a'",
        ),
        "generation_digest" => query(
            "UPDATE task_board_remote_assignments
             SET controller_lifecycle_trust_sha256 =
                 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
             WHERE assignment_id = 'assignment-a'",
        ),
        "fresh_successor" => {
            let successor = fixture_lifecycle_trust_at(7, "instance-b", true);
            query(
                "UPDATE task_board_remote_assignments
                 SET controller_operation_kind = 'offer',
                     controller_operation_request_sha256 =
                         '1111111111111111111111111111111111111111111111111111111111111111',
                     controller_operation_trust_sha256 =
                         '2222222222222222222222222222222222222222222222222222222222222222',
                     controller_operation_fence_json = ?1,
                     controller_operation_fence_sha256 = ?2
                 WHERE assignment_id = 'assignment-a'",
            )
            .bind(
                successor
                    .encoded()
                    .expect("encode successor operation fence"),
            )
            .bind(successor.snapshot_sha256)
        }
        "older_lifecycle_revision" => {
            let predecessor = fixture_lifecycle_trust_at(6, "instance-a", true);
            query(
                "UPDATE task_board_remote_assignments
                 SET controller_operation_kind = 'status',
                     controller_operation_request_sha256 =
                         '1111111111111111111111111111111111111111111111111111111111111111',
                     controller_operation_trust_sha256 =
                         '2222222222222222222222222222222222222222222222222222222222222222',
                     controller_operation_fence_json = ?1,
                     controller_operation_fence_sha256 = ?2
                 WHERE assignment_id = 'assignment-a'",
            )
            .bind(predecessor.encoded().expect("encode older operation fence"))
            .bind(predecessor.snapshot_sha256)
        }
        _ => panic!("unknown controller-operation corruption fixture"),
    };
    corrupt
        .execute(&mut *connection)
        .await
        .expect("persist corrupt controller operation token");
    connection
        .execute("PRAGMA ignore_check_constraints = OFF")
        .await
        .expect("restore strict constraints");
    drop(connection);
    db.pool().close().await;
}

async fn insert_corruptible_assignment(path: &std::path::Path) -> AsyncDaemonDb {
    let db = legacy_v40_fixture_at(path);
    drop(db);
    let db = AsyncDaemonDb::connect(path)
        .await
        .expect("migrate strict remote execution ledger");
    let request = serde_json::from_str::<RemoteOfferRequest>(&strict_request(
        "assignment-a",
        "execution-a",
        1,
        REQUEST_SHA256,
    ))
    .expect("decode strict offer request")
    .seal()
    .expect("seal strict offer request");
    let request_sha256 = request.request_sha256.clone();
    let request = serde_json::to_string(&request).expect("encode strict offer request");
    let generation = fixture_lifecycle_trust();
    let generation_json = generation
        .encoded()
        .expect("encode generation lifecycle trust");
    query(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
             host_id, target_host_instance_id, fencing_epoch, configuration_revision,
             execution_record_sha256, request_sha256, request_json,
             authenticated_principal, controller_lifecycle_trust_json,
             controller_lifecycle_trust_sha256, state, offered_at, lease_expires_at,
             deadline_at, updated_at
         ) VALUES (
             'assignment-a', 'execution-a', 'implementation', 'implementation:1', 1,
             'idempotency-assignment-a', 'executor-a', 'instance-a', 1, 7,
             'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
             ?1, ?2, 'executor:executor-a', ?3, ?4, 'offered',
             '2026-07-19T09:00:00Z',
             '2026-07-19T09:05:00Z', '2026-07-19T10:00:00Z', '2026-07-19T09:00:00Z'
         )",
    )
    .bind(request_sha256)
    .bind(request)
    .bind(generation_json)
    .bind(&generation.snapshot_sha256)
    .execute(db.pool())
    .await
    .expect("insert strict assignment");
    db
}
