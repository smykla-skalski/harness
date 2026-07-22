use rusqlite::params;

use super::tests::{insert_strict_assignment, legacy_v40_fixture, strict_request};
use super::*;
use crate::daemon::db::schema_v43::receipt_test_support::strict_claim_receipt;

#[test]
fn strict_assignment_rejects_forged_request_binding_and_duplicate_attempt() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let request = strict_request(
        "assignment-a",
        "execution-a",
        1,
        "1111111111111111111111111111111111111111111111111111111111111111",
    );
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert strict assignment");

    let forged = strict_request(
        "assignment-b",
        "wrong-execution",
        1,
        "2222222222222222222222222222222222222222222222222222222222222222",
    );
    let forged_error = insert_strict_assignment(db.connection(), "assignment-b", 2, &forged)
        .expect_err("forged execution binding must fail");
    assert!(forged_error.to_string().contains("CHECK constraint failed"));

    let duplicate = strict_request(
        "assignment-c",
        "execution-a",
        3,
        "3333333333333333333333333333333333333333333333333333333333333333",
    );
    let duplicate_error = insert_strict_assignment(db.connection(), "assignment-c", 3, &duplicate)
        .expect_err("duplicate exact attempt must fail");
    assert!(
        duplicate_error
            .to_string()
            .contains("UNIQUE constraint failed")
    );
}

#[test]
fn completed_result_must_echo_the_exact_offer_digest() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let offer_sha = "1111111111111111111111111111111111111111111111111111111111111111";
    let request = strict_request("assignment-a", "execution-a", 1, offer_sha);
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert strict assignment");
    let binding =
        serde_json::from_str::<serde_json::Value>(&request).expect("parse request")["binding"]
            .clone();
    let result_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    let status_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    let receipt = strict_claim_receipt(
        &request,
        "assignment-a",
        1,
        "lease-a",
        "2026-07-19T09:01:00Z",
    );
    let result = serde_json::json!({
        "schema_version": 1,
        "binding": binding,
        "state": "completed",
        "status_sha256": status_sha,
        "lease": null,
        "result": {
            "result": {
                "schema_version": 1,
                "execution_id": "execution-a",
                "action_key": "implementation:1",
                "attempt": 1,
                "idempotency_key": "idempotency-assignment-a"
            },
            "offer_request_sha256": offer_sha,
            "result_sha256": result_sha
        },
        "output_artifacts": {"entries": []},
        "claimed_at": "2026-07-19T09:01:00Z",
        "started_at": "2026-07-19T09:02:00Z",
        "workspace_ref": "workspace-a",
        "error_code": null,
        "observed_at": "2026-07-19T09:10:00Z",
        "offer_request_sha256": offer_sha
    });
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'completed', claimed_host_instance_id = 'instance-a',
                 lease_id = 'lease-a',
                 claimed_at = '2026-07-19T09:01:00Z',
                 started_at = '2026-07-19T09:02:00Z', workspace_ref = 'workspace-a',
                 claim_request_sha256 = ?4, claim_response_json = ?5,
                 claim_receipt_sha256 = ?6,
                 completed_at = '2026-07-19T09:10:00Z', result_json = ?1,
                 status_sha256 = ?2, result_sha256 = ?3,
                 updated_at = '2026-07-19T09:10:00Z'
             WHERE assignment_id = 'assignment-a'",
            params![
                result.to_string(),
                status_sha,
                result_sha,
                receipt.request_sha256,
                receipt.response_json,
                receipt.receipt_sha256,
            ],
        )
        .expect("store bound terminal result");

    let mut tampered = result.clone();
    tampered["offer_request_sha256"] = serde_json::Value::String("d".repeat(64));
    let error = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments SET result_json = ?1
             WHERE assignment_id = 'assignment-a'",
            [tampered.to_string()],
        )
        .expect_err("different offer digest must fail");
    assert!(error.to_string().contains("CHECK constraint failed"));

    let mut tampered_status = result;
    tampered_status["status_sha256"] = serde_json::Value::String("f".repeat(64));
    let status_error = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments SET result_json = ?1
             WHERE assignment_id = 'assignment-a'",
            [tampered_status.to_string()],
        )
        .expect_err("status envelope digest must match its durable column");
    assert!(status_error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn nonterminal_status_accepts_omitted_empty_artifacts_but_rejects_payloads() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let offer_sha = "1111111111111111111111111111111111111111111111111111111111111111";
    let request = strict_request("assignment-a", "execution-a", 1, offer_sha);
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert strict assignment");
    let binding =
        serde_json::from_str::<serde_json::Value>(&request).expect("parse request")["binding"]
            .clone();
    let status_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    let receipt = strict_claim_receipt(
        &request,
        "assignment-a",
        1,
        "lease-a",
        "2026-07-19T09:01:00Z",
    );
    let status = serde_json::json!({
        "schema_version": 1,
        "binding": binding,
        "state": "claimed",
        "status_sha256": status_sha,
        "lease": null,
        "result": null,
        "output_artifacts": {},
        "claimed_at": "2026-07-19T09:01:00Z",
        "started_at": null,
        "workspace_ref": null,
        "error_code": null,
        "observed_at": "2026-07-19T09:01:00Z",
        "offer_request_sha256": offer_sha
    });
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'claimed', claimed_host_instance_id = 'instance-a',
                 lease_id = 'lease-a', claimed_at = '2026-07-19T09:01:00Z',
                 claim_request_sha256 = ?3, claim_response_json = ?4,
                 claim_receipt_sha256 = ?5,
                 result_json = ?1, status_sha256 = ?2,
                 updated_at = '2026-07-19T09:01:00Z'
             WHERE assignment_id = 'assignment-a'",
            params![
                status.to_string(),
                status_sha,
                receipt.request_sha256,
                receipt.response_json,
                receipt.receipt_sha256,
            ],
        )
        .expect("persist omitted empty artifact entries");

    for invalid_entries in [
        serde_json::json!({}),
        serde_json::json!([{"path": "secret"}]),
    ] {
        let mut invalid = status.clone();
        invalid["output_artifacts"]["entries"] = invalid_entries;
        let error = db
            .connection()
            .execute(
                "UPDATE task_board_remote_assignments SET result_json = ?1
                 WHERE assignment_id = 'assignment-a'",
                [invalid.to_string()],
            )
            .expect_err("nonterminal status cannot carry malformed or nonempty artifacts");
        assert!(error.to_string().contains("CHECK constraint failed"));
    }
}

#[test]
fn assignment_requires_a_provisioned_configured_host_row() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    db.connection()
        .execute("DELETE FROM task_board_remote_assignments", [])
        .expect("remove migrated audit row");
    db.connection()
        .execute("DELETE FROM task_board_execution_hosts", [])
        .expect("remove configured host row");
    let request = strict_request(
        "assignment-a",
        "execution-a",
        1,
        "1111111111111111111111111111111111111111111111111111111111111111",
    );

    let error = insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect_err("host-local inbox must provision its self host row first");
    assert!(error.to_string().contains("FOREIGN KEY constraint failed"));
}

#[test]
fn executor_self_rows_forbid_controller_trust_anchors() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    db.connection()
        .execute(
            "INSERT INTO task_board_execution_hosts (
                 host_id, host_role, configured_endpoint, configured_leaf_sha256,
                 configured_credential_reference, configuration_revision, enabled,
                 created_at, updated_at
             ) VALUES (
                 'executor-self', 'executor_self', NULL, NULL, NULL, 7, 1,
                 '2026-07-19T09:00:00Z', '2026-07-19T09:00:00Z'
             )",
            [],
        )
        .expect("provision executor-local inbox identity without controller trust");

    let error = db
        .connection()
        .execute(
            "UPDATE task_board_execution_hosts
             SET configured_endpoint = 'https://attacker.example.test'
             WHERE host_id = 'executor-self'",
            [],
        )
        .expect_err("executor self row must not persist a controller endpoint");
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn executor_checkout_evidence_is_paired_positive_and_absolute() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let request = strict_request(
        "assignment-a",
        "execution-a",
        1,
        "1111111111111111111111111111111111111111111111111111111111111111",
    );
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert controller assignment without executor-local evidence");

    for (revision, checkout) in [
        (Some(7), None),
        (None, Some("/tmp/executor-a")),
        (Some(0), Some("/tmp/executor-a")),
        (Some(7), Some("relative/executor-a")),
        (Some(7), Some(" /tmp/executor-a")),
    ] {
        let error = db
            .connection()
            .execute(
                "UPDATE task_board_remote_assignments
                 SET executor_configuration_revision = ?1, executor_checkout_path = ?2
                 WHERE assignment_id = 'assignment-a'",
                params![revision, checkout],
            )
            .expect_err("malformed executor checkout evidence must fail closed");
        assert!(error.to_string().contains("CHECK constraint failed"));
    }

    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET executor_configuration_revision = 7,
                 executor_checkout_path = '/tmp/executor-a'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect("store atomic executor-local checkout evidence");
    let stored: (i64, String) = db
        .connection()
        .query_row(
            "SELECT executor_configuration_revision, executor_checkout_path
             FROM task_board_remote_assignments WHERE assignment_id = 'assignment-a'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read executor-local checkout evidence");
    assert_eq!(stored, (7, "/tmp/executor-a".into()));
}

#[derive(Debug, Clone, Copy)]
enum InvalidLegacyHost {
    HostId,
    Endpoint,
    LeafPin,
    Credential,
    Capability,
    Repository,
}

#[test]
fn migration_refuses_noncanonical_legacy_host_evidence_atomically() {
    for invalid in [
        InvalidLegacyHost::HostId,
        InvalidLegacyHost::Endpoint,
        InvalidLegacyHost::LeafPin,
        InvalidLegacyHost::Credential,
        InvalidLegacyHost::Capability,
        InvalidLegacyHost::Repository,
    ] {
        let db = legacy_v40_fixture();
        corrupt_legacy_host(db.connection(), invalid);

        let error = run(db.connection()).expect_err("invalid legacy host must fail closed");

        assert!(!error.to_string().is_empty(), "{invalid:?}");
        assert_eq!(
            db.schema_version().expect("schema version"),
            "42",
            "{invalid:?}"
        );
        let legacy_endpoint_column: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('task_board_execution_hosts')
                 WHERE name = 'endpoint'",
                [],
                |row| row.get(0),
            )
            .expect("inspect rolled-back legacy table");
        assert_eq!(legacy_endpoint_column, 1, "{invalid:?}");
    }
}

fn corrupt_legacy_host(conn: &rusqlite::Connection, invalid: InvalidLegacyHost) {
    match invalid {
        InvalidLegacyHost::HostId => conn
            .execute_batch(
                "DELETE FROM task_board_remote_assignments;
                 UPDATE task_board_execution_hosts SET host_id = 'Bad Host';
                 UPDATE task_board_orchestrator_settings
                 SET settings_json = json_set(
                     settings_json, '$.execution_hosts[0].host_id', 'Bad Host'
                 );",
            )
            .expect("corrupt host id"),
        InvalidLegacyHost::Endpoint => conn
            .execute_batch(
                "UPDATE task_board_execution_hosts
                 SET endpoint = 'https://executor.example.test/path';
                 UPDATE task_board_orchestrator_settings
                 SET settings_json = json_set(
                     settings_json, '$.execution_hosts[0].endpoint',
                     'https://executor.example.test/path'
                 );",
            )
            .expect("corrupt endpoint"),
        InvalidLegacyHost::LeafPin => {
            let mut noncanonical = crate::task_board::remote_spki_pin::encode([0; 32]);
            noncanonical.replace_range(49..50, "B");
            conn.execute(
                "UPDATE task_board_execution_hosts SET certificate_fingerprint = ?1",
                [&noncanonical],
            )
            .expect("corrupt stored pin");
            conn.execute(
                "UPDATE task_board_orchestrator_settings
                 SET settings_json = json_set(
                     settings_json, '$.execution_hosts[0].certificate_fingerprint', ?1
                 )",
                [&noncanonical],
            )
            .expect("corrupt configured pin");
        }
        InvalidLegacyHost::Credential => conn
            .execute_batch(
                "UPDATE task_board_execution_hosts SET credential_reference = 'env://BAD-NAME';
                 UPDATE task_board_orchestrator_settings
                 SET settings_json = json_set(
                     settings_json, '$.execution_hosts[0].credential_reference',
                     'env://BAD-NAME'
                 );",
            )
            .expect("corrupt credential reference"),
        InvalidLegacyHost::Capability => {
            conn.execute(
                "UPDATE task_board_execution_hosts SET capabilities_json = '[\"\"]'",
                [],
            )
            .expect("corrupt capability inventory");
        }
        InvalidLegacyHost::Repository => {
            conn.execute(
                "UPDATE task_board_execution_hosts
                 SET repositories_json = '[\" Owner/Repo \"]'",
                [],
            )
            .expect("corrupt repository inventory");
        }
    };
}

#[test]
fn strict_assignment_rejects_a_partial_no_run_failure_receipt_pair() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    let request = strict_request(
        "assignment-a",
        "execution-a",
        1,
        "1111111111111111111111111111111111111111111111111111111111111111",
    );
    insert_strict_assignment(db.connection(), "assignment-a", 1, &request)
        .expect("insert strict assignment");

    let json_only = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET executor_start_failure_receipt_json = '{\"schema_version\": 1}'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("a failure-receipt json without its digest must fail closed");
    assert!(
        json_only.to_string().contains("CHECK constraint failed"),
        "actual json-only error: {json_only}"
    );

    let digest_only = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET executor_start_failure_receipt_sha256 =
                 '2222222222222222222222222222222222222222222222222222222222222222'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("a failure-receipt digest without its json must fail closed");
    assert!(digest_only.to_string().contains("CHECK constraint failed"));

    // Malformed receipt json is rejected too, whether by the content CHECK or the
    // json parser; either way the partial write must fail closed.
    let malformed = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET executor_start_failure_receipt_json = 'not-json',
                 executor_start_failure_receipt_sha256 =
                 '3333333333333333333333333333333333333333333333333333333333333333'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("a malformed failure receipt must fail closed");
    let malformed = malformed.to_string();
    assert!(
        malformed.contains("CHECK constraint failed") || malformed.contains("malformed JSON"),
        "actual malformed error: {malformed}"
    );
}
