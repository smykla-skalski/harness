use super::tests::legacy_v40_fixture;
use super::*;
use crate::daemon::db::DaemonDb;
use rusqlite::params;

const EXECUTION_SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const DIGEST_A: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const DIGEST_B: &str = "2222222222222222222222222222222222222222222222222222222222222222";
const DIGEST_C: &str = "3333333333333333333333333333333333333333333333333333333333333333";
const DIGEST_D: &str = "4444444444444444444444444444444444444444444444444444444444444444";
const DIGEST_E: &str = "5555555555555555555555555555555555555555555555555555555555555555";

#[test]
fn rejection_receipt_accepts_unconfigured_host_without_fabricating_trust() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    let receipt = Receipt::baseline();

    insert_receipt(db.connection(), &receipt, &receipt.request_json())
        .expect("persist ineligible offer receipt");

    let configured_hosts: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM task_board_execution_hosts WHERE host_id = ?1",
            [receipt.host_id],
            |row| row.get(0),
        )
        .expect("count fabricated host rows");
    let stored: (String, String, String) = db
        .connection()
        .query_row(
            "SELECT request_sha256, rejection_code, authenticated_principal
             FROM task_board_remote_offer_receipts WHERE assignment_id = ?1",
            [receipt.assignment_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("read rejection receipt");
    assert_eq!(configured_hosts, 0);
    assert_eq!(
        stored,
        (
            DIGEST_A.into(),
            "executor_unavailable".into(),
            "executor:local-a".into()
        )
    );
}

#[test]
fn accepted_offer_receipt_freezes_the_initial_lease() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    let receipt = Receipt::baseline();

    insert_receipt_with_outcome(
        db.connection(),
        &receipt,
        &receipt.request_json(),
        Outcome::Accepted {
            lease_id: "lease-l1",
            expires_at: "2026-07-19T09:05:00Z",
        },
    )
    .expect("persist accepted offer receipt");

    let stored: (String, String, Option<String>) = db
        .connection()
        .query_row(
            "SELECT disposition, initial_lease_id, rejection_code
             FROM task_board_remote_offer_receipts WHERE assignment_id = ?1",
            [receipt.assignment_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("read accepted offer receipt");
    assert_eq!(stored, ("accepted".into(), "lease-l1".into(), None));

    let error = insert_receipt_with_outcome(
        db.connection(),
        &Receipt {
            assignment_id: "assignment-without-lease",
            execution_id: "execution-without-lease",
            idempotency_key: "idempotency-without-lease",
            request_sha256: DIGEST_B,
            fencing_epoch: 2,
            ..receipt
        },
        &Receipt {
            assignment_id: "assignment-without-lease",
            execution_id: "execution-without-lease",
            idempotency_key: "idempotency-without-lease",
            request_sha256: DIGEST_B,
            fencing_epoch: 2,
            ..receipt
        }
        .request_json(),
        Outcome::Accepted {
            lease_id: "",
            expires_at: "2026-07-19T09:05:00Z",
        },
    )
    .expect_err("accepted receipt without an initial lease must fail");
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn rejection_receipt_preserves_bounded_code_and_rejects_malformed_evidence() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    let receipt = Receipt::baseline();
    let mut forged =
        serde_json::from_str::<serde_json::Value>(&receipt.request_json()).expect("decode request");
    forged["binding"]["host_id"] = "other-host".into();

    let error = insert_receipt(db.connection(), &receipt, &forged.to_string())
        .expect_err("forged copied binding must fail");
    assert!(error.to_string().contains("CHECK constraint failed"));

    let bounded = Receipt {
        assignment_id: "assignment-b",
        execution_id: "execution-b",
        idempotency_key: "idempotency-b",
        fencing_epoch: 2,
        request_sha256: DIGEST_B,
        ..receipt
    };
    insert_receipt_with_outcome(
        db.connection(),
        &bounded,
        &bounded.request_json(),
        Outcome::Rejected("capacity_changed"),
    )
    .expect("persist bounded provider rejection code");
    let code: String = db
        .connection()
        .query_row(
            "SELECT rejection_code FROM task_board_remote_offer_receipts
             WHERE assignment_id = ?1",
            [bounded.assignment_id],
            |row| row.get(0),
        )
        .expect("read bounded rejection code");
    assert_eq!(code, "capacity_changed");

    for invalid in [
        "",
        "CapacityChanged",
        " capacity_changed",
        "capacity-changed",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ] {
        let isolated = DaemonDb::open_in_memory().expect("open isolated daemon db");
        let malformed = Receipt {
            assignment_id: "assignment-c",
            execution_id: "execution-c",
            idempotency_key: "idempotency-c",
            fencing_epoch: 3,
            request_sha256: DIGEST_C,
            ..receipt
        };
        let error = insert_receipt_with_outcome(
            isolated.connection(),
            &malformed,
            &malformed.request_json(),
            Outcome::Rejected(invalid),
        )
        .expect_err("malformed rejection code must fail");
        assert!(error.to_string().contains("CHECK constraint failed"));
    }

    let mut missing_deadline =
        serde_json::from_str::<serde_json::Value>(&receipt.request_json()).expect("decode request");
    missing_deadline
        .as_object_mut()
        .expect("request object")
        .remove("deadline_at");
    let error = insert_receipt(db.connection(), &receipt, &missing_deadline.to_string())
        .expect_err("request without deadline must fail");
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn rejection_receipt_fences_all_replay_identities() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    let baseline = Receipt::baseline();
    insert_receipt(db.connection(), &baseline, &baseline.request_json()).expect("insert baseline");

    let collisions = [
        Receipt {
            assignment_id: "assignment-b",
            execution_id: "execution-b",
            idempotency_key: baseline.idempotency_key,
            request_sha256: DIGEST_B,
            ..baseline
        },
        Receipt {
            assignment_id: "assignment-c",
            execution_id: "execution-c",
            idempotency_key: "idempotency-c",
            request_sha256: DIGEST_A,
            ..baseline
        },
        Receipt {
            assignment_id: "assignment-d",
            idempotency_key: "idempotency-d",
            request_sha256: DIGEST_D,
            fencing_epoch: 4,
            ..baseline
        },
        Receipt {
            assignment_id: "assignment-e",
            action_key: "implementation:2",
            attempt: 2,
            idempotency_key: "idempotency-e",
            request_sha256: DIGEST_E,
            ..baseline
        },
    ];
    for collision in collisions {
        let error = insert_receipt(db.connection(), &collision, &collision.request_json())
            .expect_err("replay identity collision must fail");
        assert!(error.to_string().contains("UNIQUE constraint failed"));
    }
    assert_eq!(count_receipts(&db), 1);
}

#[test]
fn v43_migration_and_repair_own_the_rejection_ledger_shape() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate v40 remote schema");
    assert_eq!(count_receipts(&db), 0);

    db.connection()
        .execute(
            "DROP INDEX task_board_remote_offer_receipts_request_digest",
            [],
        )
        .expect("drop repairable rejection index");
    run(db.connection()).expect("repair rejection index");
    let repaired: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'
             AND name = 'task_board_remote_offer_receipts_request_digest'",
            [],
            |row| row.get(0),
        )
        .expect("count repaired rejection index");
    assert_eq!(repaired, 1);

    db.connection()
        .execute(
            "ALTER TABLE task_board_remote_offer_receipts
             ADD COLUMN untrusted_response_json TEXT",
            [],
        )
        .expect("malform rejection ledger");
    let error = run(db.connection()).expect_err("malformed rejection ledger must be refused");
    assert!(error.to_string().contains("refusing destructive repair"));
}

#[derive(Clone, Copy)]
struct Receipt {
    assignment_id: &'static str,
    execution_id: &'static str,
    action_key: &'static str,
    attempt: i64,
    idempotency_key: &'static str,
    host_id: &'static str,
    fencing_epoch: i64,
    request_sha256: &'static str,
}

impl Receipt {
    fn baseline() -> Self {
        Self {
            assignment_id: "assignment-a",
            execution_id: "execution-a",
            action_key: "implementation:1",
            attempt: 1,
            idempotency_key: "idempotency-a",
            host_id: "never-configured-host",
            fencing_epoch: 1,
            request_sha256: DIGEST_A,
        }
    }

    fn request_json(self) -> String {
        serde_json::json!({
            "schema_version": 1,
            "binding": {
                "assignment_id": self.assignment_id,
                "execution_id": self.execution_id,
                "phase": "implementation",
                "workflow_kind": "default_task",
                "action_key": self.action_key,
                "attempt": self.attempt,
                "idempotency_key": self.idempotency_key,
                "host_id": self.host_id,
                "host_instance_id": "instance-a",
                "fencing_epoch": self.fencing_epoch,
                "configuration_revision": 7,
                "execution_record_sha256": EXECUTION_SHA,
                "repository": "acme/widgets",
                "base_revision": "1111111111111111111111111111111111111111"
            },
            "lease_seconds": 300,
            "deadline_at": "2026-07-19T10:00:00Z",
            "launch": {
                "schema_version": 1,
                "runtime": "codex",
                "actor": "harness-app",
                "prompt": "Implement the approved plan.",
                "mode": "workspace_write",
                "role": "leader",
                "fallback_role": "worker",
                "capabilities": ["task-board", "task-board:workflow:write"],
                "display_name": "Task Board Implementation: Widgets",
                "task_id": "task-a",
                "board_item_id": "item-a",
                "workflow_execution_id": self.execution_id,
                "allow_custom_model": false
            },
            "source": {
                "kind": "repository",
                "schema_version": 1,
                "repository": "acme/widgets",
                "selector": {"kind": "exact_revision"},
                "revision": "1111111111111111111111111111111111111111"
            },
            "artifacts": {"entries": []},
            "request_sha256": self.request_sha256,
        })
        .to_string()
    }
}

fn insert_receipt(
    conn: &Connection,
    receipt: &Receipt,
    request_json: &str,
) -> rusqlite::Result<usize> {
    insert_receipt_with_outcome(
        conn,
        receipt,
        request_json,
        Outcome::Rejected("executor_unavailable"),
    )
}

fn insert_receipt_with_outcome(
    conn: &Connection,
    receipt: &Receipt,
    request_json: &str,
    outcome: Outcome<'_>,
) -> rusqlite::Result<usize> {
    let (disposition, lease_id, lease_expires_at, rejection_code) = match outcome {
        Outcome::Accepted {
            lease_id,
            expires_at,
        } => ("accepted", Some(lease_id), Some(expires_at), None),
        Outcome::Rejected(code) => ("rejected", None, None, Some(code)),
    };
    conn.execute(
        insert_sql(),
        params![
            receipt.assignment_id,
            receipt.execution_id,
            receipt.action_key,
            receipt.attempt,
            receipt.idempotency_key,
            receipt.host_id,
            receipt.fencing_epoch,
            receipt.request_sha256,
            request_json,
            disposition,
            lease_id,
            lease_expires_at,
            rejection_code,
        ],
    )
}

fn insert_sql() -> &'static str {
    "INSERT INTO task_board_remote_offer_receipts (
         assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
         host_id, target_host_instance_id, fencing_epoch, configuration_revision,
         execution_record_sha256, request_sha256, request_json,
         authenticated_principal, disposition, initial_lease_id,
         initial_lease_expires_at, rejection_code, received_at
     ) VALUES (
         ?1, ?2, 'implementation', ?3, ?4, ?5, ?6, 'instance-a', ?7, 7,
         'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
         ?8, ?9, 'executor:local-a', ?10, ?11, ?12, ?13,
         '2026-07-19T09:00:00Z'
     )"
}

fn count_receipts(db: &DaemonDb) -> i64 {
    db.connection()
        .query_row(
            "SELECT COUNT(*) FROM task_board_remote_offer_receipts",
            [],
            |row| row.get(0),
        )
        .expect("count rejection receipts")
}

enum Outcome<'a> {
    Accepted {
        lease_id: &'a str,
        expires_at: &'a str,
    },
    Rejected(&'a str),
}
