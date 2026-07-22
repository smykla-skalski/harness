use rusqlite::Connection;

use super::CliError;

pub(super) fn run(conn: &Connection) -> Result<(), CliError> {
    if super::schema_repairs_admission::shape_needs_repair(conn)? {
        super::schema_repairs_admission::repair_and_stamp(conn)?;
    }
    super::schema_repairs_remote_execution::repair_and_stamp(conn)
}

#[cfg(test)]
pub(crate) fn restore_legacy_v40_for_test(db: &super::DaemonDb) {
    tests::restore_legacy_v40_shape(db);
}

#[cfg(test)]
#[path = "schema_v43_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "schema_v43_strict_tests.rs"]
mod strict_tests;

#[cfg(test)]
#[path = "schema_v43_replay_tests.rs"]
mod replay_tests;

#[cfg(test)]
#[path = "schema_v43_rejection_tests.rs"]
mod offer_receipt_tests;

#[cfg(test)]
#[path = "schema_v43_dispatch_tests.rs"]
mod dispatch_tests;

#[cfg(test)]
#[path = "schema_v43_partial_tests.rs"]
mod partial_tests;

#[cfg(test)]
#[path = "schema_v43_admission_shape_tests.rs"]
mod admission_shape_tests;

#[cfg(test)]
#[path = "schema_v43_settlement_tests.rs"]
mod settlement_tests;

#[cfg(test)]
#[path = "schema_v43_controller_operation_tests.rs"]
mod controller_operation_tests;

#[cfg(test)]
#[path = "schema_v43_receipt_test_support.rs"]
mod receipt_test_support;

#[cfg(test)]
#[path = "schema_v43_legacy_preservation_tests.rs"]
mod legacy_preservation_tests;

#[cfg(test)]
#[path = "schema_v43_precursor_tests.rs"]
mod precursor_tests;

#[cfg(test)]
#[path = "schema_v43_legacy_target_tests.rs"]
mod legacy_target_tests;

#[cfg(test)]
#[path = "schema_v43_handoff_tests.rs"]
mod handoff_tests;

#[cfg(test)]
#[path = "schema_v43_result_import_tests.rs"]
mod result_import_tests;

#[cfg(test)]
#[path = "schema_v43_legacy_pin_tests.rs"]
mod legacy_pin_tests;

#[cfg(test)]
#[path = "schema_v43_restart_tests.rs"]
mod restart_tests;

#[cfg(test)]
#[path = "schema_v43_tombstone_tests.rs"]
mod tombstone_tests;
