use super::tests::{insert_strict_assignment, legacy_v40_fixture, strict_request};
use super::*;
use crate::daemon::db::schema_v43::receipt_test_support::strict_claim_receipt;
use rusqlite::params;

const REQUEST_SHA: &str = "1111111111111111111111111111111111111111111111111111111111111111";

#[test]
fn accepted_assignments_require_a_lease_and_pair_mutation_replay_evidence() {
    let db = strict_assignment_fixture();
    let request = strict_request("assignment-a", "execution-a", 1, REQUEST_SHA);
    let receipt = strict_claim_receipt(
        &request,
        "assignment-a",
        1,
        "lease-a",
        "2026-07-19T09:01:00Z",
    );

    let missing_lease = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'claimed', claimed_host_instance_id = 'instance-a',
                 claimed_at = '2026-07-19T09:01:00Z'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("claimed assignment without lease must fail");
    assert!(
        missing_lease
            .to_string()
            .contains("CHECK constraint failed")
    );
    let unpaired = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments SET last_mutation_kind = 'claim'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("partial mutation replay evidence must fail");
    assert!(unpaired.to_string().contains("CHECK constraint failed"));
    let invalid = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET last_mutation_kind = 'claim-response', last_mutation_sha256 = ?1
             WHERE assignment_id = 'assignment-a'",
            [REQUEST_SHA],
        )
        .expect_err("noncanonical replay kind must fail");
    assert!(invalid.to_string().contains("CHECK constraint failed"));

    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'claimed', claimed_host_instance_id = 'instance-a',
                 lease_id = 'lease-a', claimed_at = '2026-07-19T09:01:00Z',
                 claim_request_sha256 = ?1, claim_response_json = ?2,
                 claim_receipt_sha256 = ?3,
                 last_mutation_kind = 'claim', last_mutation_sha256 = ?1
             WHERE assignment_id = 'assignment-a'",
            params![
                receipt.request_sha256,
                receipt.response_json,
                receipt.receipt_sha256,
            ],
        )
        .expect("store accepted lease and exact immutable claim receipt");
    for kind in ["claim_response", "renew_response", "cancel_response"] {
        db.connection()
            .execute(
                "UPDATE task_board_remote_assignments
                 SET last_mutation_kind = ?1, last_mutation_sha256 = ?2
                 WHERE assignment_id = 'assignment-a'",
                [kind, REQUEST_SHA],
            )
            .expect("store controller response persistence replay evidence");
    }
}

#[test]
fn rejected_offer_is_not_encoded_as_assignment_lifecycle() {
    let db = strict_assignment_fixture();
    let missing_replay = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'superseded', completed_at = '2026-07-19T09:01:00Z',
                 updated_at = '2026-07-19T09:01:00Z', error = 'executor_unavailable'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("executor rejection belongs in immutable offer receipt");
    assert!(
        missing_replay
            .to_string()
            .contains("CHECK constraint failed")
    );

    let mutation_kind = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET last_mutation_kind = 'offer_rejected', last_mutation_sha256 = ?1
             WHERE assignment_id = 'assignment-a'",
            [REQUEST_SHA],
        )
        .expect_err("assignment mutation ledger must not duplicate offer receipt");
    assert!(
        mutation_kind
            .to_string()
            .contains("CHECK constraint failed")
    );
}

fn strict_assignment_fixture() -> crate::daemon::db::DaemonDb {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let request = strict_request("assignment-a", "execution-a", 1, REQUEST_SHA);
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert strict assignment");
    db
}
