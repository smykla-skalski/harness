use super::tests::legacy_v40_fixture;
use super::*;

#[test]
fn workflow_prepared_preserves_admission_and_remains_active_unclaimed() {
    let db = legacy_v40_fixture();
    seed_reserved_admission(db.connection());

    run(db.connection()).expect("migrate dispatch and remote execution schema");
    db.connection()
        .execute(
            "UPDATE task_board_dispatch_intents SET status = 'workflow_prepared'
             WHERE intent_id = 'intent-a'",
            [],
        )
        .expect("persist prepared workflow before selecting a start target");

    let lifecycle: (String, Option<String>, Option<String>, Option<String>) = db
        .connection()
        .query_row(
            "SELECT status, claim_token, claimed_at, completed_at
             FROM task_board_dispatch_intents WHERE intent_id = 'intent-a'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .expect("read prepared dispatch lifecycle");
    assert_eq!(lifecycle, ("workflow_prepared".into(), None, None, None));
    let reserved: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
             WHERE intent_id = 'intent-a' AND state = 'reserved'",
            [],
            |row| row.get(0),
        )
        .expect("read preserved admission reservation");
    assert_eq!(reserved, 1);

    let claimed = db
        .connection()
        .execute(
            "UPDATE task_board_dispatch_intents
             SET claim_token = 'worker', claimed_at = '2026-07-19T09:01:00Z'
             WHERE intent_id = 'intent-a'",
            [],
        )
        .expect_err("prepared workflow cannot claim a local worker");
    assert!(claimed.to_string().contains("CHECK constraint failed"));
    let blank_execution = db
        .connection()
        .execute(
            "UPDATE task_board_dispatch_intents SET workflow_execution_id = ''
             WHERE intent_id = 'intent-a'",
            [],
        )
        .expect_err("prepared workflow must retain its execution identity");
    assert!(
        blank_execution
            .to_string()
            .contains("CHECK constraint failed")
    );
    db.connection()
        .execute("DROP INDEX idx_task_board_dispatch_active_item", [])
        .expect("drop repairable active-item index");
    run(db.connection()).expect("repair active-item index");
    let duplicate = db
        .connection()
        .execute(
            "INSERT INTO task_board_dispatch_intents (
                 intent_id, item_id, session_id, work_item_id, workflow_execution_id,
                 payload_json, status, attempts, available_at, created_at, updated_at
             ) VALUES (
                 'intent-b', 'item-a', 'session-b', 'work-b', 'execution-b', '{}',
                 'pending', 0, '2026-07-19T09:00:00Z', '2026-07-19T09:00:00Z',
                 '2026-07-19T09:00:00Z'
             )",
            [],
        )
        .expect_err("prepared workflow remains the one active intent for its item");
    assert!(duplicate.to_string().contains("UNIQUE constraint failed"));
}

#[test]
fn unconfigured_start_admission_is_paired_and_repair_safe() {
    let db = legacy_v40_fixture();
    seed_reserved_admission(db.connection());
    run(db.connection()).expect("migrate dispatch and remote execution schema");
    let migrated: (Option<String>, Option<i64>) = db
        .connection()
        .query_row(
            "SELECT start_admission_outcome, start_admission_settings_revision
             FROM task_board_dispatch_intents WHERE intent_id = 'intent-a'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read migrated first-start evidence");
    assert_eq!(migrated, (None, None));

    for (outcome, revision) in [
        (Some("unconfigured"), None),
        (None, Some(7)),
        (Some("unconfigured"), Some(0)),
        (Some("allowed"), Some(7)),
    ] {
        let error = db
            .connection()
            .execute(
                "UPDATE task_board_dispatch_intents
                 SET start_admission_outcome = ?1, start_admission_settings_revision = ?2
                 WHERE intent_id = 'intent-a'",
                rusqlite::params![outcome, revision],
            )
            .expect_err("malformed first-start evidence must fail closed");
        assert!(error.to_string().contains("CHECK constraint failed"));
    }

    db.connection()
        .execute(
            "UPDATE task_board_dispatch_intents
             SET start_admission_outcome = 'unconfigured',
                 start_admission_settings_revision = 7
             WHERE intent_id = 'intent-a'",
            [],
        )
        .expect("freeze unconfigured first-start admission evidence");
    db.connection()
        .execute("DROP INDEX idx_task_board_dispatch_active_item", [])
        .expect("drop repairable active-item index");
    run(db.connection()).expect("repair active-item index");

    let repaired: (String, i64) = db
        .connection()
        .query_row(
            "SELECT start_admission_outcome, start_admission_settings_revision
             FROM task_board_dispatch_intents WHERE intent_id = 'intent-a'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read repaired first-start evidence");
    assert_eq!(repaired, ("unconfigured".into(), 7));
}

fn seed_reserved_admission(conn: &rusqlite::Connection) {
    conn.execute_batch(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, created_at, updated_at
         ) VALUES (
             'intent-a', 'item-a', 'session-a', 'work-a', 'execution-a', '{}',
             'pending', 0, '2026-07-19T09:00:00Z', '2026-07-19T09:00:00Z',
             '2026-07-19T09:00:00Z'
         );
         INSERT INTO task_board_dispatch_admission_decisions (
             decision_id, intent_id, generation, item_id, item_revision,
             settings_revision, decision, policy_json, context_json,
             requirements_json, blockers_json, launch_profile, evaluated_at,
             is_current, created_at
         ) VALUES (
             'decision-a', 'intent-a', 1, 'item-a', 1, 7, 'allowed', '{}', '{}',
             '[]', '[]', 'workspace_write', '2026-07-19T09:00:00Z', 1,
             '2026-07-19T09:00:00Z'
         );
         INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id,
             canonical_key, kind, scope, amount, limit_value, state, expires_at,
             reserved_at
         ) VALUES (
             'ledger-a', 'decision-a', 'allowed', 'intent-a', 1, 'item-a',
             'global:concurrency', 'concurrency', 'global', 1, 2, 'reserved',
             '2026-07-19T09:05:00Z', '2026-07-19T09:00:00Z'
         );",
    )
    .expect("seed reserved v40 admission evidence");
}
