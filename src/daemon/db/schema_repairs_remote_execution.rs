use rusqlite::{OptionalExtension, Transaction, TransactionBehavior};

use super::{CliError, Connection, db_error};

#[path = "schema_repairs_remote_execution_legacy.rs"]
mod legacy;

use legacy::validate_legacy_host_evidence;

#[path = "schema_repairs_remote_execution_quarantine.rs"]
mod quarantine;

#[path = "schema_repairs_remote_execution_precursor.rs"]
mod precursor;

const HOST_TABLE: &str = "task_board_execution_hosts";
const ASSIGNMENT_TABLE: &str = "task_board_remote_assignments";
const OFFER_RECEIPT_TABLE: &str = "task_board_remote_offer_receipts";
const SETTLEMENT_RECEIPT_TABLE: &str = "task_board_remote_settlement_receipts";
const SOURCE_BUNDLE_TABLE: &str = "task_board_remote_source_bundles";
const OUTBOUND_SOURCE_TABLE: &str = "task_board_remote_outbound_sources";
const SOURCE_BUNDLE_ABANDONMENT_TABLE: &str =
    "task_board_remote_source_bundle_abandonments";
const ARTIFACT_TABLE: &str = "task_board_remote_artifacts";
const RESULT_IMPORT_TABLE: &str = "task_board_remote_result_imports";
const RECOVERY_QUARANTINE_TABLE: &str = "task_board_remote_recovery_quarantine";
const DISPATCH_TABLE: &str = "task_board_dispatch_intents";
const ADMISSION_DECISION_TABLE: &str = "task_board_dispatch_admission_decisions";
const ADMISSION_LEDGER_TABLE: &str = "task_board_dispatch_admission_ledger";
const OBSOLETE_ACTIVE_INDEX: &str = "task_board_remote_assignments_one_active_phase";
const DISPATCH_ACTIVE_INDEX: &str = "idx_task_board_dispatch_active_item";
const MIGRATION_SQL: &str =
    include_str!("migrations/0037_daemon_v43_task_board_remote_execution.sql");

const LEGACY_HOST_TABLE_SQL: &str = "
CREATE TABLE task_board_execution_hosts (
    host_id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, certificate_fingerprint TEXT NOT NULL,
    credential_reference TEXT NOT NULL, protocol_version INTEGER NOT NULL,
    capabilities_json TEXT NOT NULL, repositories_json TEXT NOT NULL, capacity INTEGER NOT NULL,
    active_assignments INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL, updated_at TEXT NOT NULL
) WITHOUT ROWID";

const LEGACY_ASSIGNMENT_TABLE_SQL: &str = "
CREATE TABLE task_board_remote_assignments (
    assignment_id TEXT PRIMARY KEY, execution_id TEXT NOT NULL
        REFERENCES task_board_workflow_executions(execution_id) ON DELETE CASCADE,
    phase TEXT NOT NULL, host_id TEXT NOT NULL REFERENCES task_board_execution_hosts(host_id),
    idempotency_key TEXT NOT NULL UNIQUE, fencing_epoch INTEGER NOT NULL, state TEXT NOT NULL,
    offered_at TEXT NOT NULL, acknowledged_at TEXT, started_at TEXT, heartbeat_at TEXT,
    completed_at TEXT, result_json TEXT, error TEXT
) WITHOUT ROWID";

const LEGACY_DISPATCH_ACTIVE_INDEXES: &[&str] = &[
    "CREATE UNIQUE INDEX idx_task_board_dispatch_active_item
        ON task_board_dispatch_intents(item_id)
        WHERE status IN ('preparing', 'preparing_claimed', 'pending', 'starting')",
    "CREATE UNIQUE INDEX idx_task_board_dispatch_active_item
        ON task_board_dispatch_intents(item_id)
        WHERE status IN ('preparing', 'preparing_claimed', 'held', 'pending', 'starting')",
];

pub(super) const LEGACY_DISPATCH_TABLE_SQL: &str = "
CREATE TABLE task_board_dispatch_intents (
    intent_id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES task_board_items(item_id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    work_item_id TEXT NOT NULL,
    workflow_execution_id TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'preparing', 'preparing_claimed', 'held', 'pending', 'starting', 'completed', 'failed'
    )),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at TEXT NOT NULL,
    claim_token TEXT,
    claimed_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,
    consumed_approval_grant_id TEXT,
    compensation_pending INTEGER NOT NULL DEFAULT 0 CHECK (
        compensation_pending IN (0, 1)
        AND (
            compensation_pending = 0
            OR (
                status IN ('pending', 'starting')
                AND last_error IS NOT NULL
                AND length(last_error) > 0
            )
        )
    ),
    CHECK (
        (status IN ('preparing_claimed', 'starting')
            AND claim_token IS NOT NULL AND claimed_at IS NOT NULL)
        OR
        (status NOT IN ('preparing_claimed', 'starting')
            AND claim_token IS NULL AND claimed_at IS NULL)
    ),
    CHECK (
        (status IN ('completed', 'failed') AND completed_at IS NOT NULL)
        OR
        (status NOT IN ('completed', 'failed') AND completed_at IS NULL)
    )
)";

const INDEX_DDL: &str = "
DROP INDEX IF EXISTS task_board_remote_assignments_one_active_phase;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_assignments_identity_epoch
    ON task_board_remote_assignments(assignment_id, fencing_epoch);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_assignments_exact_attempt
    ON task_board_remote_assignments(execution_id, action_key, attempt)
    WHERE legacy_migrated = 0
      AND state IN ('offered', 'claimed', 'started', 'running', 'unknown');
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_assignments_active_idempotency
    ON task_board_remote_assignments(idempotency_key)
    WHERE legacy_migrated = 0
      AND state IN ('offered', 'claimed', 'started', 'running', 'unknown');
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_assignments_execution_epoch
    ON task_board_remote_assignments(execution_id, fencing_epoch)
    WHERE legacy_migrated = 0;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_assignments_request_digest
    ON task_board_remote_assignments(request_sha256)
    WHERE legacy_migrated = 0;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_assignments_host_lease
    ON task_board_remote_assignments(host_id, lease_id)
    WHERE lease_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS task_board_remote_assignments_active_host
    ON task_board_remote_assignments(
        host_id, state, lease_expires_at, deadline_at, assignment_id
    )
    WHERE cleanup_completed_at IS NULL
      AND (
        state IN ('offered', 'claimed', 'started', 'running')
        OR (
          state IN ('completed', 'failed', 'cancelled', 'superseded', 'unknown')
          AND claimed_at IS NOT NULL
        )
      );
CREATE INDEX IF NOT EXISTS task_board_remote_assignments_exact_attempt_history
    ON task_board_remote_assignments(
        execution_id, action_key, attempt, fencing_epoch DESC, assignment_id
    );
CREATE INDEX IF NOT EXISTS task_board_remote_assignments_recovery
    ON task_board_remote_assignments(
        state, lease_expires_at, deadline_at, updated_at, assignment_id
    )
    WHERE state IN ('offered', 'claimed', 'started', 'running', 'unknown');
CREATE INDEX IF NOT EXISTS task_board_execution_hosts_eligible
    ON task_board_execution_hosts(
        host_role, enabled, observed_state, observed_received_at,
        observed_heartbeat_at, host_id
    );
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_offer_receipts_idempotency
    ON task_board_remote_offer_receipts(idempotency_key);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_offer_receipts_request_digest
    ON task_board_remote_offer_receipts(request_sha256);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_offer_receipts_exact_attempt
    ON task_board_remote_offer_receipts(execution_id, action_key, attempt);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_offer_receipts_execution_epoch
    ON task_board_remote_offer_receipts(execution_id, fencing_epoch);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_settlement_receipts_request_digest
    ON task_board_remote_settlement_receipts(request_sha256);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_settlement_receipts_exact_attempt
    ON task_board_remote_settlement_receipts(execution_id, action_key, attempt);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_settlement_receipts_execution_epoch
    ON task_board_remote_settlement_receipts(execution_id, fencing_epoch);
CREATE INDEX IF NOT EXISTS task_board_remote_settlement_receipts_retention
    ON task_board_remote_settlement_receipts(settled_at, assignment_id);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_source_bundles_offer_digest
    ON task_board_remote_source_bundles(offer_request_sha256);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_source_bundles_upload_digest
    ON task_board_remote_source_bundles(upload_request_sha256);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_outbound_sources_offer_digest
    ON task_board_remote_outbound_sources(offer_request_sha256);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_outbound_sources_upload_digest
    ON task_board_remote_outbound_sources(upload_request_sha256);
CREATE INDEX IF NOT EXISTS task_board_remote_outbound_sources_attempt
    ON task_board_remote_outbound_sources(
        execution_id, action_key, attempt, fencing_epoch, assignment_id
    );
CREATE INDEX IF NOT EXISTS task_board_remote_source_bundle_abandonments_attempt
    ON task_board_remote_source_bundle_abandonments(
        execution_id, action_key, attempt, fencing_epoch
    );
CREATE UNIQUE INDEX IF NOT EXISTS task_board_remote_source_bundle_abandonments_generation
    ON task_board_remote_source_bundle_abandonments(execution_id, fencing_epoch);
CREATE INDEX IF NOT EXISTS task_board_remote_artifacts_retention
    ON task_board_remote_artifacts(stored_at, assignment_id, fencing_epoch);
CREATE INDEX IF NOT EXISTS task_board_remote_result_imports_recovery
    ON task_board_remote_result_imports(state, prepared_at, assignment_id, fencing_epoch)
    WHERE state IN ('prepared', 'applied');
CREATE INDEX IF NOT EXISTS task_board_remote_recovery_quarantine_retry
    ON task_board_remote_recovery_quarantine(next_attempt_at, assignment_id);
CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_intents_admission_identity
    ON task_board_dispatch_intents(intent_id, item_id);
CREATE INDEX IF NOT EXISTS idx_task_board_dispatch_intents_pending
    ON task_board_dispatch_intents(status, available_at, updated_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_dispatch_session_work_item
    ON task_board_dispatch_intents(session_id, work_item_id);
DROP INDEX IF EXISTS idx_task_board_dispatch_active_item;
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_board_dispatch_active_item
    ON task_board_dispatch_intents(item_id)
    WHERE status IN (
        'preparing', 'preparing_claimed', 'held', 'pending',
        'workflow_prepared', 'starting'
    );
CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_admission_decisions_current_intent
    ON task_board_dispatch_admission_decisions(intent_id)
    WHERE intent_id IS NOT NULL AND is_current = 1;
CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_admission_decisions_current_item
    ON task_board_dispatch_admission_decisions(item_id)
    WHERE intent_id IS NULL AND is_current = 1;
CREATE INDEX IF NOT EXISTS task_board_dispatch_admission_decisions_item_history
    ON task_board_dispatch_admission_decisions(
        item_id, created_at DESC, generation DESC, decision_id
    );
CREATE UNIQUE INDEX IF NOT EXISTS task_board_dispatch_admission_ledger_current_requirement
    ON task_board_dispatch_admission_ledger(intent_id, canonical_key)
    WHERE state IN ('reserved', 'committed');
CREATE INDEX IF NOT EXISTS task_board_dispatch_admission_ledger_usage
    ON task_board_dispatch_admission_ledger(
        kind, scope, window_started_at, window_ends_at, state
    );
CREATE INDEX IF NOT EXISTS task_board_dispatch_admission_ledger_intent_generation
    ON task_board_dispatch_admission_ledger(
        intent_id, generation, state, canonical_key
    );
";

const EXPECTED_INDEXES: &[&str] = &[
    "task_board_remote_assignments_identity_epoch",
    "task_board_remote_assignments_exact_attempt",
    "task_board_remote_assignments_active_idempotency",
    "task_board_remote_assignments_execution_epoch",
    "task_board_remote_assignments_request_digest",
    "task_board_remote_assignments_host_lease",
    "task_board_remote_assignments_active_host",
    "task_board_remote_assignments_exact_attempt_history",
    "task_board_remote_assignments_recovery",
    "task_board_execution_hosts_eligible",
    "task_board_remote_offer_receipts_idempotency",
    "task_board_remote_offer_receipts_request_digest",
    "task_board_remote_offer_receipts_exact_attempt",
    "task_board_remote_offer_receipts_execution_epoch",
    "task_board_remote_settlement_receipts_request_digest",
    "task_board_remote_settlement_receipts_exact_attempt",
    "task_board_remote_settlement_receipts_execution_epoch",
    "task_board_remote_settlement_receipts_retention",
    "task_board_remote_source_bundles_offer_digest",
    "task_board_remote_source_bundles_upload_digest",
    "task_board_remote_outbound_sources_offer_digest",
    "task_board_remote_outbound_sources_upload_digest",
    "task_board_remote_outbound_sources_attempt",
    "task_board_remote_source_bundle_abandonments_attempt",
    "task_board_remote_source_bundle_abandonments_generation",
    "task_board_remote_artifacts_retention",
    "task_board_remote_result_imports_recovery",
    "task_board_remote_recovery_quarantine_retry",
    "task_board_dispatch_intents_admission_identity",
    "idx_task_board_dispatch_intents_pending",
    "idx_task_board_dispatch_session_work_item",
    "idx_task_board_dispatch_active_item",
    "task_board_dispatch_admission_decisions_current_intent",
    "task_board_dispatch_admission_decisions_current_item",
    "task_board_dispatch_admission_decisions_item_history",
    "task_board_dispatch_admission_ledger_current_requirement",
    "task_board_dispatch_admission_ledger_usage",
    "task_board_dispatch_admission_ledger_intent_generation",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RemoteSchemaShape {
    LegacyV36,
    /// A precursor v43 whose remote-assignment ledger predates the no-run
    /// Start-failure receipt columns; repaired in place by adding them NULL.
    PreFailureReceiptV43,
    CurrentV43,
}

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    match classify_shape(conn)? {
        RemoteSchemaShape::LegacyV36 | RemoteSchemaShape::PreFailureReceiptV43 => Ok(true),
        RemoteSchemaShape::CurrentV43 => indexes_need_repair(conn),
    }
}

pub(super) fn repair_and_stamp(conn: &Connection) -> Result<(), CliError> {
    // The precursor rebuild swaps a table that child foreign keys reference, so it
    // must suspend foreign_keys enforcement - a no-op inside a transaction - and
    // therefore runs in its own transaction rather than the shared one below.
    if classify_shape(conn)? == RemoteSchemaShape::PreFailureReceiptV43 {
        return precursor::rebuild_prefailure_receipt_assignment(conn);
    }
    let transaction = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)
        .map_err(|error| db_error(format!("begin remote execution schema repair: {error}")))?;
    match classify_shape(&transaction)? {
        RemoteSchemaShape::LegacyV36 => {
            validate_legacy_host_evidence(&transaction)?;
            transaction
                .execute_batch(MIGRATION_SQL)
                .map_err(|error| db_error(format!("migrate remote execution schema: {error}")))?;
        }
        RemoteSchemaShape::PreFailureReceiptV43 => {
            return Err(db_error(
                "precursor remote execution shape must repair with foreign keys suspended",
            ));
        }
        RemoteSchemaShape::CurrentV43 => {
            transaction
                .execute_batch(INDEX_DDL)
                .map_err(|error| db_error(format!("repair remote execution indexes: {error}")))?;
            transaction
                .execute(
                    "UPDATE schema_meta SET value = '43' WHERE key = 'version'",
                    [],
                )
                .map_err(|error| db_error(format!("stamp remote execution schema: {error}")))?;
        }
    }
    require_complete_shape(&transaction)?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit remote execution schema repair: {error}")))
}

pub(super) fn require_complete_shape(conn: &Connection) -> Result<(), CliError> {
    if classify_shape(conn)? != RemoteSchemaShape::CurrentV43 {
        return Err(incompatible_schema());
    }
    if indexes_need_repair(conn)? {
        return Err(db_error(
            "remote execution schema repair left required indexes missing",
        ));
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn classification_for_test(conn: &Connection) -> String {
    match classify_shape(conn) {
        Ok(shape) => format!("{shape:?}"),
        Err(error) => format!("Err: {error}"),
    }
}

fn classify_shape(conn: &Connection) -> Result<RemoteSchemaShape, CliError> {
    let host_sql = table_sql(conn, HOST_TABLE)?;
    let assignment_sql = table_sql(conn, ASSIGNMENT_TABLE)?;
    let offer_receipt_sql = table_sql(conn, OFFER_RECEIPT_TABLE)?;
    let settlement_receipt_sql = table_sql(conn, SETTLEMENT_RECEIPT_TABLE)?;
    let source_bundle_sql = table_sql(conn, SOURCE_BUNDLE_TABLE)?;
    let outbound_source_sql = table_sql(conn, OUTBOUND_SOURCE_TABLE)?;
    let source_bundle_abandonment_sql = table_sql(conn, SOURCE_BUNDLE_ABANDONMENT_TABLE)?;
    let artifact_sql = table_sql(conn, ARTIFACT_TABLE)?;
    let result_import_sql = table_sql(conn, RESULT_IMPORT_TABLE)?;
    let recovery_quarantine_sql = table_sql(conn, RECOVERY_QUARANTINE_TABLE)?;
    let dispatch_sql = table_sql(conn, DISPATCH_TABLE)?;
    let admission_decision_sql = table_sql(conn, ADMISSION_DECISION_TABLE)?;
    let admission_ledger_sql = table_sql(conn, ADMISSION_LEDGER_TABLE)?;
    let (Some(host_sql), Some(assignment_sql), Some(dispatch_sql)) =
        (host_sql, assignment_sql, dispatch_sql)
    else {
        return Err(db_error(
            "missing remote execution ledger table; refusing destructive repair",
        ));
    };
    // Every ledger table other than the remote-assignment table shares one
    // current-shape gate; the assignment table then decides current vs precursor.
    let others_current = is_expected_table(&host_sql, HOST_TABLE)?
        && table_current(&offer_receipt_sql, OFFER_RECEIPT_TABLE)?
        && table_current(&settlement_receipt_sql, SETTLEMENT_RECEIPT_TABLE)?
        && table_current(&source_bundle_sql, SOURCE_BUNDLE_TABLE)?
        && table_current(&outbound_source_sql, OUTBOUND_SOURCE_TABLE)?
        && table_current(&source_bundle_abandonment_sql, SOURCE_BUNDLE_ABANDONMENT_TABLE)?
        && table_current(&artifact_sql, ARTIFACT_TABLE)?
        && table_current(&result_import_sql, RESULT_IMPORT_TABLE)?
        && table_current(&recovery_quarantine_sql, RECOVERY_QUARANTINE_TABLE)?
        && quarantine::current_shape_matches(conn)?
        && is_expected_table(&dispatch_sql, DISPATCH_TABLE)?
        && table_current(&admission_decision_sql, ADMISSION_DECISION_TABLE)?
        && table_current(&admission_ledger_sql, ADMISSION_LEDGER_TABLE)?;
    if others_current && is_expected_table(&assignment_sql, ASSIGNMENT_TABLE)? {
        return Ok(RemoteSchemaShape::CurrentV43);
    }
    // A precursor v43: the remote-assignment table is v43-era (has the start
    // receipt) but predates the no-run Start-failure receipt columns.
    if others_current && precursor::assignment_is_prefailure(conn)? {
        return Ok(RemoteSchemaShape::PreFailureReceiptV43);
    }
    if normalize_sql(&host_sql) == normalize_sql(LEGACY_HOST_TABLE_SQL)
        && normalize_sql(&assignment_sql) == normalize_sql(LEGACY_ASSIGNMENT_TABLE_SQL)
        && offer_receipt_sql.is_none()
        && settlement_receipt_sql.is_none()
        && source_bundle_sql.is_none()
        && outbound_source_sql.is_none()
        && source_bundle_abandonment_sql.is_none()
        && artifact_sql.is_none()
        && result_import_sql.is_none()
        && recovery_quarantine_sql.is_none()
        && quarantine::legacy_absent(conn)?
        && normalize_sql(&dispatch_sql) == normalize_sql(LEGACY_DISPATCH_TABLE_SQL)
    {
        return Ok(RemoteSchemaShape::LegacyV36);
    }
    Err(incompatible_schema())
}

fn indexes_need_repair(conn: &Connection) -> Result<bool, CliError> {
    let mut needs_repair = object_sql(conn, "index", OBSOLETE_ACTIVE_INDEX)?.is_some();
    for name in EXPECTED_INDEXES {
        let Some(actual) = object_sql(conn, "index", name)? else {
            needs_repair = true;
            continue;
        };
        if normalize_sql(&actual) != expected_index_sql(name)? {
            if is_repairable_legacy_index(name, &actual) {
                needs_repair = true;
                continue;
            }
            return Err(db_error(format!(
                "incompatible remote execution index '{name}'; refusing destructive repair"
            )));
        }
    }
    Ok(needs_repair)
}

fn is_repairable_legacy_index(name: &str, actual: &str) -> bool {
    name == DISPATCH_ACTIVE_INDEX
        && LEGACY_DISPATCH_ACTIVE_INDEXES
            .iter()
            .any(|expected| normalize_sql(actual) == normalize_sql(expected))
}

fn is_expected_table(stored_sql: &str, table: &str) -> Result<bool, CliError> {
    Ok(normalize_sql(stored_sql) == expected_table_sql(table)?)
}

/// A present optional table matches the current shape; an absent one is not.
fn table_current(stored_sql: &Option<String>, table: &str) -> Result<bool, CliError> {
    stored_sql
        .as_deref()
        .map(|sql| is_expected_table(sql, table))
        .transpose()
        .map(|current| current.unwrap_or(false))
}

fn expected_table_sql(table: &str) -> Result<String, CliError> {
    let marker = format!("CREATE TABLE {table} (");
    extract_statement(MIGRATION_SQL, &marker)
}

fn expected_index_sql(name: &str) -> Result<String, CliError> {
    let unique_marker = format!("CREATE UNIQUE INDEX {name}");
    if MIGRATION_SQL.contains(&unique_marker) {
        return extract_statement(MIGRATION_SQL, &unique_marker);
    }
    extract_statement(MIGRATION_SQL, &format!("CREATE INDEX {name}"))
}

fn extract_statement(sql: &str, marker: &str) -> Result<String, CliError> {
    let start = sql.find(marker).ok_or_else(|| {
        db_error(format!(
            "remote execution migration is missing statement '{marker}'"
        ))
    })?;
    let statement = sql[start..]
        .split_once(';')
        .map(|(statement, _)| statement)
        .ok_or_else(|| {
            db_error(format!(
                "remote execution migration statement '{marker}' is unterminated"
            ))
        })?;
    Ok(normalize_sql(statement))
}

fn table_sql(conn: &Connection, table: &str) -> Result<Option<String>, CliError> {
    object_sql(conn, "table", table)
}

fn object_sql(
    conn: &Connection,
    object_type: &str,
    name: &str,
) -> Result<Option<String>, CliError> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = ?1 AND name = ?2",
        [object_type, name],
        |row| row.get(0),
    )
    .optional()
    .map_err(|error| {
        db_error(format!(
            "read remote execution schema object {name}: {error}"
        ))
    })
}

fn incompatible_schema() -> CliError {
    db_error("incompatible remote execution ledger schema; refusing destructive repair")
}

fn normalize_sql(sql: &str) -> String {
    super::schema_repairs::normalize_schema_sql(sql)
}
