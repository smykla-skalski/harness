use crate::daemon::db::DaemonDb;

pub(super) fn restore_original_v34_upgrade_shape(db: &DaemonDb) {
    // This compatibility test starts from the current sync snapshot so it can
    // seed one historical SQLx ledger row. A version stamp alone is not a
    // historical schema: strict v43 correctly rejects current remote tables
    // paired with a partially downgraded dispatch table. Restore the remote
    // and dispatch lineage to shapes the v35 -> v43 chain can actually emit,
    // then remove the v35 and v39 effects exercised by that chain.
    harness_db_schema::schema_v43::restore_legacy_v40_for_test(db.connection());
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
