pub(super) const INDEX_DDL: &str = "
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

pub(super) const EXPECTED_INDEXES: &[&str] = &[
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
