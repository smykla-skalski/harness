CREATE TEMP TABLE task_board_remote_v43_guard (
    valid INTEGER NOT NULL
        CONSTRAINT remote_v43_operator_trust_must_match CHECK (valid = 1)
);

INSERT INTO task_board_remote_v43_guard (valid)
SELECT CASE WHEN EXISTS (
    SELECT 1
    FROM task_board_orchestrator_settings
    WHERE singleton = 1
      AND json_valid(settings_json)
      AND json_type(
          settings_json, '$._v43_legacy_execution_host_quarantine'
      ) IS NULL
      AND (
          json_type(settings_json, '$.execution_hosts') IS NULL
          OR json_type(settings_json, '$.execution_hosts') = 'array'
      )
) THEN 1 ELSE 0 END;

INSERT INTO task_board_remote_v43_guard (valid)
SELECT CASE WHEN NOT EXISTS (
    SELECT 1
    FROM task_board_orchestrator_settings AS settings,
         json_each(COALESCE(json_extract(settings.settings_json, '$.execution_hosts'), '[]')) AS host
    WHERE settings.singleton = 1
      AND (
          json_type(host.value) != 'object'
          OR typeof(json_extract(host.value, '$.host_id')) != 'text'
          OR length(trim(json_extract(host.value, '$.host_id'))) = 0
          OR typeof(json_extract(host.value, '$.endpoint')) != 'text'
          OR json_extract(host.value, '$.endpoint') NOT LIKE 'https://%'
          OR typeof(json_extract(host.value, '$.certificate_fingerprint')) != 'text'
          OR NOT (
              (
                  length(json_extract(host.value, '$.certificate_fingerprint')) = 51
                  AND substr(
                      json_extract(host.value, '$.certificate_fingerprint'), 1, 7
                  ) = 'sha256/'
                  AND substr(
                      json_extract(host.value, '$.certificate_fingerprint'), 8, 42
                  ) NOT GLOB '*[^A-Za-z0-9+/]*'
                  AND substr(
                      json_extract(host.value, '$.certificate_fingerprint'), 50, 1
                  ) GLOB '[AEIMQUYcgkosw048]'
                  AND substr(
                      json_extract(host.value, '$.certificate_fingerprint'), 51, 1
                  ) = '='
              )
              OR (
                  length(json_extract(host.value, '$.certificate_fingerprint')) = 64
                  AND json_extract(host.value, '$.certificate_fingerprint')
                      NOT GLOB '*[^0-9a-f]*'
              )
          )
          OR typeof(json_extract(host.value, '$.credential_reference')) != 'text'
          OR length(trim(json_extract(host.value, '$.credential_reference'))) = 0
          OR COALESCE(json_extract(host.value, '$.enabled'), 1) NOT IN (0, 1)
      )
) THEN 1 ELSE 0 END;

INSERT INTO task_board_remote_v43_guard (valid)
SELECT CASE WHEN NOT EXISTS (
    SELECT 1
    FROM task_board_execution_hosts AS stored
    WHERE NOT EXISTS (
        SELECT 1
        FROM task_board_orchestrator_settings AS settings,
             json_each(COALESCE(json_extract(settings.settings_json, '$.execution_hosts'), '[]')) AS host
        WHERE settings.singleton = 1
          AND json_extract(host.value, '$.host_id') = stored.host_id
          AND json_extract(host.value, '$.endpoint') = stored.endpoint
          AND json_extract(host.value, '$.certificate_fingerprint') = stored.certificate_fingerprint
          AND json_extract(host.value, '$.credential_reference') = stored.credential_reference
    )
) THEN 1 ELSE 0 END;

-- Rebuild the admission FK chain child-first so the dispatch status CHECK can
-- grow without disabling foreign-key enforcement or losing reserved budget.
ALTER TABLE task_board_dispatch_admission_ledger
    RENAME TO task_board_dispatch_admission_ledger_v40;
ALTER TABLE task_board_dispatch_admission_decisions
    RENAME TO task_board_dispatch_admission_decisions_v40;
ALTER TABLE task_board_dispatch_intents
    RENAME TO task_board_dispatch_intents_v40;
DROP INDEX IF EXISTS task_board_dispatch_intents_admission_identity;

CREATE TABLE task_board_dispatch_intents (
    intent_id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES task_board_items(item_id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    work_item_id TEXT NOT NULL,
    workflow_execution_id TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'preparing', 'preparing_claimed', 'held', 'pending', 'workflow_prepared',
        'starting', 'completed', 'failed'
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
    compensation_pending INTEGER NOT NULL DEFAULT 0
        CHECK (
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
    start_admission_outcome TEXT,
    start_admission_settings_revision INTEGER,
    CHECK (COALESCE((
        (
            start_admission_outcome IS NULL
            AND start_admission_settings_revision IS NULL
        )
        OR (
            start_admission_outcome = 'unconfigured'
            AND typeof(start_admission_settings_revision) = 'integer'
            AND start_admission_settings_revision > 0
        )
    ), 0)),
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
    ),
    CHECK (
        status != 'workflow_prepared'
        OR (
            length(trim(workflow_execution_id)) > 0
            AND compensation_pending = 0
            AND claim_token IS NULL
            AND claimed_at IS NULL
            AND completed_at IS NULL
        )
    )
);

CREATE UNIQUE INDEX task_board_dispatch_intents_admission_identity
    ON task_board_dispatch_intents(intent_id, item_id);

CREATE TABLE task_board_dispatch_admission_decisions (
    decision_id TEXT PRIMARY KEY CHECK (length(decision_id) > 0),
    intent_id TEXT,
    generation INTEGER NOT NULL
        CHECK (typeof(generation) = 'integer' AND generation > 0),
    item_id TEXT NOT NULL,
    item_revision INTEGER NOT NULL
        CHECK (typeof(item_revision) = 'integer' AND item_revision > 0),
    settings_revision INTEGER NOT NULL
        CHECK (typeof(settings_revision) = 'integer' AND settings_revision > 0),
    decision TEXT NOT NULL
        CHECK (decision IN ('allowed', 'deferred', 'rejected')),
    policy_json TEXT NOT NULL
        CHECK (json_valid(policy_json) AND json_type(policy_json) = 'object'),
    context_json TEXT NOT NULL
        CHECK (json_valid(context_json) AND json_type(context_json) = 'object'),
    requirements_json TEXT NOT NULL
        CHECK (json_valid(requirements_json) AND json_type(requirements_json) = 'array'),
    blockers_json TEXT NOT NULL
        CHECK (json_valid(blockers_json) AND json_type(blockers_json) = 'array'),
    launch_profile TEXT
        CHECK (launch_profile IS NULL OR launch_profile IN ('read_only', 'workspace_write')),
    evaluated_at TEXT NOT NULL CHECK (evaluated_at GLOB '????-??-??T??:??:??Z'),
    next_available_at TEXT
        CHECK (next_available_at IS NULL OR next_available_at GLOB '????-??-??T??:??:??Z'),
    is_current INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0, 1)),
    superseded_at TEXT
        CHECK (superseded_at IS NULL OR superseded_at GLOB '????-??-??T??:??:??Z'),
    created_at TEXT NOT NULL CHECK (created_at GLOB '????-??-??T??:??:??Z'),
    CHECK (
        (decision = 'allowed' AND intent_id IS NOT NULL)
        OR (decision IN ('deferred', 'rejected') AND intent_id IS NULL)
    ),
    CHECK (decision = 'deferred' OR (decision != 'deferred' AND next_available_at IS NULL)),
    CHECK (
        (is_current = 1 AND superseded_at IS NULL)
        OR (
            is_current = 0
            AND superseded_at IS NOT NULL
            AND superseded_at >= created_at
        )
    ),
    UNIQUE(intent_id, generation),
    UNIQUE(item_id, generation),
    UNIQUE(decision_id, intent_id, generation, item_id, decision),
    FOREIGN KEY (intent_id, item_id)
        REFERENCES task_board_dispatch_intents(intent_id, item_id)
        ON DELETE RESTRICT,
    FOREIGN KEY (item_id)
        REFERENCES task_board_items(item_id)
        ON DELETE RESTRICT
) WITHOUT ROWID;

CREATE TABLE task_board_dispatch_admission_ledger (
    ledger_id TEXT PRIMARY KEY CHECK (length(ledger_id) > 0),
    decision_id TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (decision = 'allowed'),
    intent_id TEXT NOT NULL,
    generation INTEGER NOT NULL
        CHECK (typeof(generation) = 'integer' AND generation > 0),
    item_id TEXT NOT NULL,
    canonical_key TEXT NOT NULL CHECK (length(canonical_key) > 0),
    kind TEXT NOT NULL CHECK (
        kind IN ('concurrency', 'rate', 'time_window', 'token_budget', 'monetary_budget')
    ),
    scope TEXT NOT NULL CHECK (length(scope) > 0),
    amount INTEGER NOT NULL CHECK (typeof(amount) = 'integer' AND amount >= 0),
    limit_value INTEGER NOT NULL
        CHECK (typeof(limit_value) = 'integer' AND limit_value > 0),
    window_started_at TEXT
        CHECK (window_started_at IS NULL OR window_started_at GLOB '????-??-??T??:??:??Z'),
    window_ends_at TEXT
        CHECK (window_ends_at IS NULL OR window_ends_at GLOB '????-??-??T??:??:??Z'),
    state TEXT NOT NULL CHECK (state IN ('reserved', 'committed', 'released')),
    managed_worker_id TEXT CHECK (managed_worker_id IS NULL OR length(managed_worker_id) > 0),
    expires_at TEXT CHECK (expires_at IS NULL OR expires_at GLOB '????-??-??T??:??:??Z'),
    reserved_at TEXT NOT NULL CHECK (reserved_at GLOB '????-??-??T??:??:??Z'),
    committed_at TEXT
        CHECK (committed_at IS NULL OR committed_at GLOB '????-??-??T??:??:??Z'),
    released_at TEXT CHECK (released_at IS NULL OR released_at GLOB '????-??-??T??:??:??Z'),
    CHECK (
        (
            kind = 'concurrency'
            AND amount > 0
            AND window_started_at IS NULL
            AND window_ends_at IS NULL
        )
        OR (
            kind = 'rate'
            AND amount > 0
            AND window_started_at IS NOT NULL
            AND window_ends_at > window_started_at
        )
        OR (
            kind = 'time_window'
            AND amount = 0
            AND window_started_at IS NOT NULL
            AND window_ends_at > window_started_at
        )
        OR (
            kind IN ('token_budget', 'monetary_budget')
            AND amount > 0
            AND window_started_at IS NOT NULL
            AND window_ends_at > window_started_at
        )
    ),
    CHECK (
        (
            state = 'reserved'
            AND managed_worker_id IS NULL
            AND expires_at IS NOT NULL
            AND expires_at > reserved_at
            AND committed_at IS NULL
            AND released_at IS NULL
        )
        OR (
            state = 'committed'
            AND managed_worker_id IS NOT NULL
            AND expires_at IS NULL
            AND committed_at IS NOT NULL
            AND committed_at >= reserved_at
            AND released_at IS NULL
        )
        OR (
            state = 'released'
            AND expires_at IS NULL
            AND released_at IS NOT NULL
            AND (
                (
                    committed_at IS NULL
                    AND managed_worker_id IS NULL
                    AND released_at >= reserved_at
                )
                OR (
                    kind = 'concurrency'
                    AND committed_at IS NOT NULL
                    AND managed_worker_id IS NOT NULL
                    AND committed_at >= reserved_at
                    AND released_at >= committed_at
                )
            )
        )
    ),
    UNIQUE(decision_id, canonical_key),
    FOREIGN KEY (decision_id, intent_id, generation, item_id, decision)
        REFERENCES task_board_dispatch_admission_decisions(
            decision_id, intent_id, generation, item_id, decision
        )
        ON DELETE RESTRICT
) WITHOUT ROWID;

INSERT INTO task_board_dispatch_intents (
    intent_id, item_id, session_id, work_item_id, workflow_execution_id,
    payload_json, status, attempts, available_at, claim_token, claimed_at,
    last_error, created_at, updated_at, completed_at,
    consumed_approval_grant_id, compensation_pending,
    start_admission_outcome, start_admission_settings_revision
)
SELECT
    intent_id, item_id, session_id, work_item_id, workflow_execution_id,
    payload_json, status, attempts, available_at, claim_token, claimed_at,
    last_error, created_at, updated_at, completed_at,
    consumed_approval_grant_id, compensation_pending, NULL, NULL
FROM task_board_dispatch_intents_v40;

INSERT INTO task_board_dispatch_admission_decisions
SELECT * FROM task_board_dispatch_admission_decisions_v40;
INSERT INTO task_board_dispatch_admission_ledger
SELECT * FROM task_board_dispatch_admission_ledger_v40;

DROP TABLE task_board_dispatch_admission_ledger_v40;
DROP TABLE task_board_dispatch_admission_decisions_v40;
DROP TABLE task_board_dispatch_intents_v40;

CREATE INDEX idx_task_board_dispatch_intents_pending
    ON task_board_dispatch_intents(status, available_at, updated_at);
CREATE UNIQUE INDEX idx_task_board_dispatch_session_work_item
    ON task_board_dispatch_intents(session_id, work_item_id);
CREATE UNIQUE INDEX idx_task_board_dispatch_active_item
    ON task_board_dispatch_intents(item_id)
    WHERE status IN (
        'preparing', 'preparing_claimed', 'held', 'pending',
        'workflow_prepared', 'starting'
    );
CREATE UNIQUE INDEX task_board_dispatch_admission_decisions_current_intent
    ON task_board_dispatch_admission_decisions(intent_id)
    WHERE intent_id IS NOT NULL AND is_current = 1;
CREATE UNIQUE INDEX task_board_dispatch_admission_decisions_current_item
    ON task_board_dispatch_admission_decisions(item_id)
    WHERE intent_id IS NULL AND is_current = 1;
CREATE INDEX task_board_dispatch_admission_decisions_item_history
    ON task_board_dispatch_admission_decisions(
        item_id, created_at DESC, generation DESC, decision_id
    );
CREATE UNIQUE INDEX task_board_dispatch_admission_ledger_current_requirement
    ON task_board_dispatch_admission_ledger(intent_id, canonical_key)
    WHERE state IN ('reserved', 'committed');
CREATE INDEX task_board_dispatch_admission_ledger_usage
    ON task_board_dispatch_admission_ledger(
        kind, scope, window_started_at, window_ends_at, state
    );
CREATE INDEX task_board_dispatch_admission_ledger_intent_generation
    ON task_board_dispatch_admission_ledger(
        intent_id, generation, state, canonical_key
    );

DROP INDEX IF EXISTS task_board_remote_assignments_one_active_phase;
ALTER TABLE task_board_remote_assignments
    RENAME TO task_board_remote_assignments_v36;
ALTER TABLE task_board_execution_hosts
    RENAME TO task_board_execution_hosts_v36;

CREATE TABLE task_board_execution_hosts (
    host_id TEXT PRIMARY KEY
        CHECK (typeof(host_id) = 'text' AND length(trim(host_id)) > 0),
    host_role TEXT NOT NULL
        CHECK (host_role IN ('controller_remote', 'executor_self', 'legacy_tombstone')),
    configured_endpoint TEXT,
    configured_leaf_sha256 TEXT,
    configured_credential_reference TEXT,
    configuration_revision INTEGER NOT NULL
        CHECK (typeof(configuration_revision) = 'integer'
               AND configuration_revision > 0),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    observed_host_instance_id TEXT,
    observed_protocol_version INTEGER,
    observed_capabilities_json TEXT,
    observed_repositories_json TEXT,
    observed_runtimes_json TEXT,
    observed_capacity INTEGER,
    observed_active_assignments INTEGER,
    observed_state TEXT,
    observed_heartbeat_at TEXT,
    observed_received_at TEXT,
    advertisement_sha256 TEXT,
    created_at TEXT NOT NULL CHECK (length(trim(created_at)) > 0),
    updated_at TEXT NOT NULL CHECK (length(trim(updated_at)) > 0),
    CHECK (COALESCE((
        (
            host_role = 'controller_remote'
            AND typeof(configured_endpoint) = 'text'
            AND configured_endpoint LIKE 'https://%'
            AND typeof(configured_leaf_sha256) = 'text'
            AND length(configured_leaf_sha256) = 51
            AND substr(configured_leaf_sha256, 1, 7) = 'sha256/'
            AND substr(configured_leaf_sha256, 8, 42) NOT GLOB '*[^A-Za-z0-9+/]*'
            AND substr(configured_leaf_sha256, 50, 1) GLOB '[AEIMQUYcgkosw048]'
            AND substr(configured_leaf_sha256, 51, 1) = '='
            AND typeof(configured_credential_reference) = 'text'
            AND length(trim(configured_credential_reference)) > 0
        )
        OR (
            host_role = 'executor_self'
            AND configured_endpoint IS NULL
            AND configured_leaf_sha256 IS NULL
            AND configured_credential_reference IS NULL
        )
        OR (
            -- Inert tombstone for a quarantined legacy host: keeps the exact
            -- host_id so historical assignment foreign keys resolve, but carries
            -- no trust material and can never be selected for admission.
            host_role = 'legacy_tombstone'
            AND enabled = 0
            AND configured_endpoint IS NULL
            AND configured_leaf_sha256 IS NULL
            AND configured_credential_reference IS NULL
        )
    ), 0)),
    CHECK (COALESCE((
        (
            observed_host_instance_id IS NULL
            AND observed_protocol_version IS NULL
            AND observed_capabilities_json IS NULL
            AND observed_repositories_json IS NULL
            AND observed_runtimes_json IS NULL
            AND observed_capacity IS NULL
            AND observed_active_assignments IS NULL
            AND observed_state IS NULL
            AND observed_heartbeat_at IS NULL
            AND observed_received_at IS NULL
            AND advertisement_sha256 IS NULL
        )
        OR (
            typeof(observed_host_instance_id) = 'text'
            AND length(trim(observed_host_instance_id)) > 0
            AND typeof(observed_protocol_version) = 'integer'
            AND observed_protocol_version > 0
            AND json_valid(observed_capabilities_json)
            AND json_type(observed_capabilities_json) = 'array'
            AND json_valid(observed_repositories_json)
            AND json_type(observed_repositories_json) = 'array'
            AND json_valid(observed_runtimes_json)
            AND json_type(observed_runtimes_json) = 'array'
            AND typeof(observed_capacity) = 'integer'
            AND observed_capacity > 0
            AND typeof(observed_active_assignments) = 'integer'
            AND observed_active_assignments BETWEEN 0 AND observed_capacity
            AND observed_state IN ('healthy', 'degraded', 'unavailable')
            AND typeof(observed_heartbeat_at) = 'text'
            AND length(trim(observed_heartbeat_at)) > 0
            AND typeof(observed_received_at) = 'text'
            AND length(trim(observed_received_at)) > 0
            AND typeof(advertisement_sha256) = 'text'
            AND length(advertisement_sha256) = 64
            AND advertisement_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ), 0)),
    -- A legacy tombstone is structurally inert: it can never carry observation
    -- or advertisement evidence, so no raw INSERT/UPDATE can dress it up as a
    -- live, schedulable host.
    CHECK (host_role != 'legacy_tombstone' OR (
        observed_host_instance_id IS NULL
        AND observed_protocol_version IS NULL
        AND observed_capabilities_json IS NULL
        AND observed_repositories_json IS NULL
        AND observed_runtimes_json IS NULL
        AND observed_capacity IS NULL
        AND observed_active_assignments IS NULL
        AND observed_state IS NULL
        AND observed_heartbeat_at IS NULL
        AND observed_received_at IS NULL
        AND advertisement_sha256 IS NULL
    ))
) WITHOUT ROWID;

-- v40 accepted a lowercase leaf-certificate SHA-256. It is not an SPKI pin and
-- must never be reinterpreted as one. Preserve the exact operator evidence in
-- a diagnostic-only quarantine entry, remove the host from executable
-- settings, and require an explicit repair or re-pair before new admission.
UPDATE task_board_orchestrator_settings AS settings
SET settings_json = json_set(
    settings.settings_json,
    '$._v43_legacy_execution_host_quarantine',
    json((
        SELECT json_group_array(json_object(
            'reason', 'legacy_leaf_certificate_sha256_requires_repair',
            'configuration_revision', settings.revision,
            'quarantined_at', settings.updated_at,
            'host', json(host.value)
        ))
        FROM json_each(
            COALESCE(json_extract(settings.settings_json, '$.execution_hosts'), '[]')
        ) AS host
        WHERE length(json_extract(host.value, '$.certificate_fingerprint')) = 64
          AND json_extract(host.value, '$.certificate_fingerprint')
              NOT GLOB '*[^0-9a-f]*'
    )),
    '$.execution_hosts',
    json((
        SELECT json_group_array(json(host.value))
        FROM json_each(
            COALESCE(json_extract(settings.settings_json, '$.execution_hosts'), '[]')
        ) AS host
        WHERE length(json_extract(host.value, '$.certificate_fingerprint')) = 51
          AND substr(
              json_extract(host.value, '$.certificate_fingerprint'), 1, 7
          ) = 'sha256/'
          AND substr(
              json_extract(host.value, '$.certificate_fingerprint'), 8, 42
          ) NOT GLOB '*[^A-Za-z0-9+/]*'
          AND substr(
              json_extract(host.value, '$.certificate_fingerprint'), 50, 1
          ) GLOB '[AEIMQUYcgkosw048]'
          AND substr(
              json_extract(host.value, '$.certificate_fingerprint'), 51, 1
          ) = '='
    ))
)
WHERE settings.singleton = 1
  AND EXISTS (
      SELECT 1
      FROM json_each(
          COALESCE(json_extract(settings.settings_json, '$.execution_hosts'), '[]')
      ) AS host
      WHERE length(json_extract(host.value, '$.certificate_fingerprint')) = 64
        AND json_extract(host.value, '$.certificate_fingerprint')
            NOT GLOB '*[^0-9a-f]*'
  );

-- Trust anchors come only from the operator-owned settings singleton. The
-- legacy observation row is used solely by the guards above and never seeds
-- configured endpoint, pin, or credential values.
INSERT INTO task_board_execution_hosts (
    host_id,
    host_role,
    configured_endpoint,
    configured_leaf_sha256,
    configured_credential_reference,
    configuration_revision,
    enabled,
    created_at,
    updated_at
)
SELECT
    json_extract(host.value, '$.host_id'),
    'controller_remote',
    json_extract(host.value, '$.endpoint'),
    json_extract(host.value, '$.certificate_fingerprint'),
    json_extract(host.value, '$.credential_reference'),
    settings.revision,
    COALESCE(json_extract(host.value, '$.enabled'), 1),
    settings.updated_at,
    settings.updated_at
FROM task_board_orchestrator_settings AS settings,
     json_each(COALESCE(json_extract(settings.settings_json, '$.execution_hosts'), '[]')) AS host
WHERE settings.singleton = 1;

-- Any v36 host referenced by a historical assignment but absent from the
-- rebuilt trusted hosts (leaf-pin quarantine, operator removal, disable, or
-- stale settings) needs an inert parent so the assignment foreign key resolves.
-- Build these tombstones from the exact referenced host ids, never from old
-- trust material: they are disabled, carry no endpoint/pin/credential, and are
-- filtered out of every admission and trust query by host_role/enabled. The
-- legacy quarantine JSON stays diagnostic-only.
INSERT INTO task_board_execution_hosts (
    host_id,
    host_role,
    configuration_revision,
    enabled,
    created_at,
    updated_at
)
SELECT DISTINCT
    inert.host_id,
    'legacy_tombstone',
    settings.revision,
    0,
    settings.updated_at,
    settings.updated_at
FROM task_board_orchestrator_settings AS settings,
     (
        -- (1) Every quarantined settings host, so a leaf-pin host with zero
        -- historical assignments still gains an inert parent and provenance.
        SELECT json_extract(entry.value, '$.host.host_id') AS host_id
        FROM task_board_orchestrator_settings AS quarantine_settings,
             json_each(COALESCE(json_extract(
                 quarantine_settings.settings_json,
                 '$._v43_legacy_execution_host_quarantine'
             ), '[]')) AS entry
        WHERE quarantine_settings.singleton = 1
        UNION
        -- (2) Every legacy assignment host absent from the rebuilt trusted hosts
        -- (operator removal, disable, or stale settings).
        SELECT host_id FROM task_board_remote_assignments_v36
     ) AS inert
WHERE settings.singleton = 1
  AND typeof(inert.host_id) = 'text'
  AND length(trim(inert.host_id)) > 0
  AND inert.host_id NOT IN (SELECT host_id FROM task_board_execution_hosts);

-- Durable, immutable home for quarantined legacy host evidence. The transient
-- settings JSON key is erased by any later settings rewrite, so the exact
-- operator evidence lives here instead, keyed to (and fenced by) the inert
-- tombstone host. No runtime code updates, deletes, or prunes this table, and it
-- never joins scheduling or trust.
CREATE TABLE task_board_remote_host_quarantines (
    host_id TEXT PRIMARY KEY
        REFERENCES task_board_execution_hosts(host_id) ON DELETE RESTRICT
        CHECK (typeof(host_id) = 'text' AND length(trim(host_id)) > 0),
    reason TEXT NOT NULL
        CHECK (reason IN ('legacy_leaf_certificate_sha256_requires_repair')),
    source_settings_revision INTEGER NOT NULL
        CHECK (typeof(source_settings_revision) = 'integer'
               AND source_settings_revision > 0),
    source_settings_updated_at TEXT NOT NULL
        CHECK (length(trim(source_settings_updated_at)) > 0),
    legacy_endpoint TEXT NOT NULL
        CHECK (typeof(legacy_endpoint) = 'text' AND legacy_endpoint LIKE 'https://%'),
    legacy_leaf_sha256 TEXT NOT NULL
        CHECK (length(legacy_leaf_sha256) = 64
               AND legacy_leaf_sha256 NOT GLOB '*[^0-9a-f]*'),
    legacy_credential_reference TEXT NOT NULL
        CHECK (typeof(legacy_credential_reference) = 'text'
               AND length(trim(legacy_credential_reference)) > 0),
    legacy_enabled INTEGER NOT NULL
        CHECK (legacy_enabled IN (0, 1))
) WITHOUT ROWID;

INSERT INTO task_board_remote_host_quarantines (
    host_id, reason, source_settings_revision, source_settings_updated_at,
    legacy_endpoint, legacy_leaf_sha256, legacy_credential_reference, legacy_enabled
)
SELECT
    json_extract(entry.value, '$.host.host_id'),
    json_extract(entry.value, '$.reason'),
    json_extract(entry.value, '$.configuration_revision'),
    json_extract(entry.value, '$.quarantined_at'),
    json_extract(entry.value, '$.host.endpoint'),
    json_extract(entry.value, '$.host.certificate_fingerprint'),
    json_extract(entry.value, '$.host.credential_reference'),
    COALESCE(json_extract(entry.value, '$.host.enabled'), 1)
FROM task_board_orchestrator_settings AS settings,
     json_each(COALESCE(json_extract(
         settings.settings_json, '$._v43_legacy_execution_host_quarantine'
     ), '[]')) AS entry
WHERE settings.singleton = 1
  AND json_extract(entry.value, '$.host.host_id')
      IN (SELECT host_id FROM task_board_execution_hosts);

-- The migration above is the only legitimate writer of this ledger. Freeze it
-- completely: no runtime INSERT (which could fabricate operator evidence on a
-- re-paired live host), no UPDATE (even a no-op), and no DELETE (which would
-- silently erase quarantine provenance the transient settings key no longer
-- holds). Restart classification requires these three exact trigger bodies.
CREATE TRIGGER task_board_remote_host_quarantines_reject_insert
BEFORE INSERT ON task_board_remote_host_quarantines
BEGIN
    SELECT RAISE(ABORT, 'task_board_remote_host_quarantines is immutable');
END;
CREATE TRIGGER task_board_remote_host_quarantines_reject_update
BEFORE UPDATE ON task_board_remote_host_quarantines
BEGIN
    SELECT RAISE(ABORT, 'task_board_remote_host_quarantines is immutable');
END;
CREATE TRIGGER task_board_remote_host_quarantines_reject_delete
BEFORE DELETE ON task_board_remote_host_quarantines
BEGIN
    SELECT RAISE(ABORT, 'task_board_remote_host_quarantines is immutable');
END;

-- The evidence is now durable in the ledger; drop the fragile settings key so a
-- later settings rewrite cannot appear to have silently erased it.
UPDATE task_board_orchestrator_settings
SET settings_json =
    json_remove(settings_json, '$._v43_legacy_execution_host_quarantine')
WHERE singleton = 1
  AND json_type(settings_json, '$._v43_legacy_execution_host_quarantine') IS NOT NULL;

-- Deliberately omit an execution foreign key. Controller writes fence the
-- parent full-record CAS and exact attempt in one transaction, while the same
-- ledger can serve a host-local inbox without fabricating a workflow shadow.
CREATE TABLE task_board_remote_assignments (
    assignment_id TEXT PRIMARY KEY
        CHECK (typeof(assignment_id) = 'text' AND length(trim(assignment_id)) > 0),
    execution_id TEXT NOT NULL
        CHECK (typeof(execution_id) = 'text' AND length(trim(execution_id)) > 0),
    phase TEXT NOT NULL CHECK (length(trim(phase)) > 0),
    action_key TEXT,
    attempt INTEGER,
    idempotency_key TEXT NOT NULL
        CHECK (typeof(idempotency_key) = 'text' AND length(trim(idempotency_key)) > 0),
    host_id TEXT NOT NULL REFERENCES task_board_execution_hosts(host_id),
    target_host_instance_id TEXT,
    claimed_host_instance_id TEXT,
    lease_id TEXT,
    fencing_epoch INTEGER NOT NULL
        CHECK (typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0),
    configuration_revision INTEGER,
    execution_record_sha256 TEXT,
    request_sha256 TEXT,
    request_json TEXT,
    authenticated_principal TEXT,
    claim_request_sha256 TEXT,
    claim_response_json TEXT,
    claim_receipt_sha256 TEXT,
    controller_lifecycle_trust_json TEXT,
    controller_lifecycle_trust_sha256 TEXT,
    controller_operation_kind TEXT,
    controller_operation_request_sha256 TEXT,
    controller_operation_trust_sha256 TEXT,
    controller_operation_fence_json TEXT,
    controller_operation_fence_sha256 TEXT,
    controller_handoff_kind TEXT,
    controller_handoff_execution_sha256 TEXT,
    controller_handoff_successor_assignment_id TEXT,
    controller_handoff_successor_fencing_epoch INTEGER,
    controller_handoff_at TEXT,
    last_mutation_kind TEXT,
    last_mutation_sha256 TEXT,
    state TEXT NOT NULL CHECK (
        state IN (
            'offered', 'claimed', 'started', 'running', 'completed', 'failed',
            'cancelled', 'superseded', 'unknown'
        )
    ),
    legacy_migrated INTEGER NOT NULL DEFAULT 0 CHECK (legacy_migrated IN (0, 1)),
    offered_at TEXT NOT NULL CHECK (length(trim(offered_at)) > 0),
    claimed_at TEXT,
    started_at TEXT,
    heartbeat_at TEXT,
    lease_expires_at TEXT,
    deadline_at TEXT,
    cancel_requested_at TEXT,
    completed_at TEXT,
    workspace_ref TEXT,
    executor_configuration_revision INTEGER,
    executor_checkout_path TEXT,
    executor_start_authority_sha256 TEXT,
    executor_start_authority_at TEXT,
    executor_start_io_permit_sha256 TEXT,
    executor_start_io_permit_at TEXT,
    executor_start_receipt_json TEXT,
    executor_start_receipt_sha256 TEXT,
    executor_start_failure_receipt_json TEXT,
    executor_start_failure_receipt_sha256 TEXT,
    executor_lifecycle_owner_instance_id TEXT,
    executor_lifecycle_owner_epoch INTEGER,
    executor_lifecycle_owner_acquired_at TEXT,
    executor_lifecycle_owner_expires_at TEXT,
    executor_lifecycle_owner_sha256 TEXT,
    executor_stop_pending_json TEXT,
    executor_stop_pending_sha256 TEXT,
    result_json TEXT,
    status_sha256 TEXT,
    result_sha256 TEXT,
    cleanup_settlement_request_sha256 TEXT,
    cleanup_completed_at TEXT,
    error TEXT,
    updated_at TEXT NOT NULL CHECK (length(trim(updated_at)) > 0),
    CHECK (COALESCE((
        (
            legacy_migrated = 1
            AND state = 'superseded'
            AND action_key IS NULL
            AND attempt IS NULL
            AND target_host_instance_id IS NULL
            AND claimed_host_instance_id IS NULL
            AND lease_id IS NULL
            AND configuration_revision IS NULL
            AND execution_record_sha256 IS NULL
            AND request_sha256 IS NULL
            AND request_json IS NULL
            AND authenticated_principal IS NULL
            AND claim_request_sha256 IS NULL
            AND claim_response_json IS NULL
            AND claim_receipt_sha256 IS NULL
            AND controller_lifecycle_trust_json IS NULL
            AND controller_lifecycle_trust_sha256 IS NULL
            AND controller_operation_kind IS NULL
            AND controller_operation_request_sha256 IS NULL
            AND controller_operation_trust_sha256 IS NULL
            AND controller_operation_fence_json IS NULL
            AND controller_operation_fence_sha256 IS NULL
            AND controller_handoff_kind IS NULL
            AND controller_handoff_execution_sha256 IS NULL
            AND controller_handoff_successor_assignment_id IS NULL
            AND controller_handoff_successor_fencing_epoch IS NULL
            AND controller_handoff_at IS NULL
            AND last_mutation_kind IS NULL
            AND last_mutation_sha256 IS NULL
            AND lease_expires_at IS NULL
            AND deadline_at IS NULL
            AND workspace_ref IS NULL
            AND executor_configuration_revision IS NULL
            AND executor_checkout_path IS NULL
            AND executor_start_authority_sha256 IS NULL
            AND executor_start_authority_at IS NULL
            AND executor_start_io_permit_sha256 IS NULL
            AND executor_start_io_permit_at IS NULL
            AND executor_start_receipt_json IS NULL
            AND executor_start_receipt_sha256 IS NULL
            AND executor_start_failure_receipt_json IS NULL
            AND executor_start_failure_receipt_sha256 IS NULL
            AND executor_lifecycle_owner_instance_id IS NULL
            AND executor_lifecycle_owner_epoch IS NULL
            AND executor_lifecycle_owner_acquired_at IS NULL
            AND executor_lifecycle_owner_expires_at IS NULL
            AND executor_lifecycle_owner_sha256 IS NULL
            AND executor_stop_pending_json IS NULL
            AND executor_stop_pending_sha256 IS NULL
            AND status_sha256 IS NULL
            AND result_sha256 IS NULL
            AND cleanup_settlement_request_sha256 IS NULL
            AND cleanup_completed_at IS NULL
        )
        OR (
            legacy_migrated = 0
            AND phase IN ('implementation', 'review', 'evaluate')
            AND typeof(action_key) = 'text'
            AND length(trim(action_key)) > 0
            AND typeof(attempt) = 'integer'
            AND attempt > 0
            AND typeof(target_host_instance_id) = 'text'
            AND length(trim(target_host_instance_id)) > 0
            AND typeof(configuration_revision) = 'integer'
            AND configuration_revision > 0
            AND typeof(execution_record_sha256) = 'text'
            AND length(execution_record_sha256) = 64
            AND execution_record_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(request_sha256) = 'text'
            AND length(request_sha256) = 64
            AND request_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(request_json) = 'text'
            AND json_valid(request_json)
            AND json_type(request_json) = 'object'
            AND json_extract(request_json, '$.schema_version') = 1
            AND json_extract(request_json, '$.binding.assignment_id') = assignment_id
            AND json_extract(request_json, '$.binding.execution_id') = execution_id
            AND json_extract(request_json, '$.binding.phase') = phase
            AND json_extract(request_json, '$.binding.action_key') = action_key
            AND json_extract(request_json, '$.binding.attempt') = attempt
            AND json_extract(request_json, '$.binding.idempotency_key') = idempotency_key
            AND json_extract(request_json, '$.binding.host_id') = host_id
            AND json_extract(request_json, '$.binding.host_instance_id') = target_host_instance_id
            AND json_extract(request_json, '$.binding.fencing_epoch') = fencing_epoch
            AND json_extract(request_json, '$.binding.configuration_revision') = configuration_revision
            AND json_extract(request_json, '$.binding.execution_record_sha256') = execution_record_sha256
            AND json_extract(request_json, '$.request_sha256') = request_sha256
            AND json_extract(request_json, '$.deadline_at') = deadline_at
            AND typeof(authenticated_principal) = 'text'
            AND length(trim(authenticated_principal)) > 0
            AND typeof(lease_expires_at) = 'text'
            AND length(trim(lease_expires_at)) > 0
            AND typeof(deadline_at) = 'text'
            AND length(trim(deadline_at)) > 0
        )
    ), 0)),
    CHECK (COALESCE((
        claimed_host_instance_id IS NULL
        OR (
            typeof(claimed_host_instance_id) = 'text'
            AND length(trim(claimed_host_instance_id)) > 0
            AND claimed_host_instance_id = target_host_instance_id
        )
    ), 0)),
    CHECK (COALESCE((
        (
            executor_start_receipt_json IS NULL
            AND executor_start_receipt_sha256 IS NULL
        )
        OR (
            legacy_migrated = 0
            AND state IN ('started', 'running', 'completed', 'failed', 'cancelled', 'unknown')
            AND executor_start_authority_sha256 IS NULL
            AND executor_start_authority_at IS NULL
            AND executor_start_io_permit_sha256 IS NULL
            AND executor_start_io_permit_at IS NULL
            AND typeof(executor_start_receipt_json) = 'text'
            AND length(executor_start_receipt_json) <= 32768
            AND json_valid(executor_start_receipt_json)
            AND json_type(executor_start_receipt_json) = 'object'
            AND json_extract(executor_start_receipt_json, '$.schema_version') = 1
            AND json_extract(executor_start_receipt_json, '$.assignment_id') = assignment_id
            AND json_extract(executor_start_receipt_json, '$.fencing_epoch') = fencing_epoch
            AND json_extract(executor_start_receipt_json, '$.offer_request_sha256') = request_sha256
            AND json_extract(executor_start_receipt_json, '$.claim_receipt_sha256') = claim_receipt_sha256
            AND typeof(json_extract(
                executor_start_receipt_json, '$.start_io_permit_sha256'
            )) = 'text'
            AND length(json_extract(
                executor_start_receipt_json, '$.start_io_permit_sha256'
            )) = 64
            AND json_extract(
                executor_start_receipt_json, '$.start_io_permit_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND typeof(json_extract(
                executor_start_receipt_json, '$.start_io_permit_at'
            )) = 'text'
            AND length(trim(json_extract(
                executor_start_receipt_json, '$.start_io_permit_at'
            ))) > 0
            AND typeof(json_extract(
                executor_start_receipt_json, '$.start_io_lease_id'
            )) = 'text'
            AND length(trim(json_extract(
                executor_start_receipt_json, '$.start_io_lease_id'
            ))) > 0
            AND typeof(json_extract(
                executor_start_receipt_json, '$.start_io_lease_expires_at'
            )) = 'text'
            AND length(trim(json_extract(
                executor_start_receipt_json, '$.start_io_lease_expires_at'
            ))) > 0
            AND typeof(json_extract(
                executor_start_receipt_json, '$.start_io_deadline_at'
            )) = 'text'
            AND length(trim(json_extract(
                executor_start_receipt_json, '$.start_io_deadline_at'
            ))) > 0
            AND json_extract(executor_start_receipt_json, '$.started_at') = started_at
            AND json_extract(executor_start_receipt_json, '$.workspace_ref') = workspace_ref
            AND json_extract(
                executor_start_receipt_json, '$.executor_configuration_revision'
            ) = executor_configuration_revision
            AND json_extract(
                executor_start_receipt_json, '$.executor_checkout_path'
            ) = executor_checkout_path
            AND json_extract(executor_start_receipt_json, '$.initial_owner_epoch') = 1
            AND typeof(json_extract(
                executor_start_receipt_json, '$.initial_owner_instance_id'
            )) = 'text'
            AND length(trim(json_extract(
                executor_start_receipt_json, '$.initial_owner_instance_id'
            ))) > 0
            AND typeof(executor_start_receipt_sha256) = 'text'
            AND length(executor_start_receipt_sha256) = 64
            AND executor_start_receipt_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ), 0)),
    CHECK (COALESCE((
        (
            executor_start_failure_receipt_json IS NULL
            AND executor_start_failure_receipt_sha256 IS NULL
        )
        OR (
            legacy_migrated = 0
            AND state = 'failed'
            AND started_at IS NULL
            AND workspace_ref IS NULL
            AND executor_start_receipt_json IS NULL
            AND executor_start_receipt_sha256 IS NULL
            AND executor_start_authority_sha256 IS NULL
            AND executor_start_io_permit_sha256 IS NULL
            AND executor_lifecycle_owner_sha256 IS NULL
            AND result_json IS NULL
            AND status_sha256 IS NULL
            AND result_sha256 IS NULL
            AND typeof(executor_start_failure_receipt_json) = 'text'
            AND length(executor_start_failure_receipt_json) <= 32768
            AND json_valid(executor_start_failure_receipt_json)
            AND json_type(executor_start_failure_receipt_json) = 'object'
            AND json_extract(executor_start_failure_receipt_json, '$.schema_version') = 1
            AND json_extract(executor_start_failure_receipt_json, '$.assignment_id') = assignment_id
            AND json_extract(executor_start_failure_receipt_json, '$.fencing_epoch') = fencing_epoch
            AND json_extract(executor_start_failure_receipt_json, '$.offer_request_sha256') = request_sha256
            AND json_extract(executor_start_failure_receipt_json, '$.claim_receipt_sha256') = claim_receipt_sha256
            AND typeof(json_extract(
                executor_start_failure_receipt_json, '$.start_authority_sha256'
            )) = 'text'
            AND length(json_extract(
                executor_start_failure_receipt_json, '$.start_authority_sha256'
            )) = 64
            AND json_extract(
                executor_start_failure_receipt_json, '$.start_authority_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND typeof(json_extract(
                executor_start_failure_receipt_json, '$.start_io_permit_sha256'
            )) = 'text'
            AND length(json_extract(
                executor_start_failure_receipt_json, '$.start_io_permit_sha256'
            )) = 64
            AND json_extract(
                executor_start_failure_receipt_json, '$.start_io_permit_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND typeof(json_extract(
                executor_start_failure_receipt_json, '$.error_code'
            )) = 'text'
            AND length(trim(json_extract(
                executor_start_failure_receipt_json, '$.error_code'
            ))) > 0
            AND json_extract(executor_start_failure_receipt_json, '$.failure_class') IN (
                'transient', 'permanent', 'authentication',
                'configuration', 'policy', 'conflict'
            )
            AND typeof(json_extract(
                executor_start_failure_receipt_json, '$.status_sha256'
            )) = 'text'
            AND length(json_extract(
                executor_start_failure_receipt_json, '$.status_sha256'
            )) = 64
            AND json_extract(
                executor_start_failure_receipt_json, '$.status_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND json_extract(
                executor_start_failure_receipt_json, '$.status_response.state'
            ) = 'failed'
            AND json_extract(
                executor_start_failure_receipt_json, '$.status_response.status_sha256'
            ) = json_extract(executor_start_failure_receipt_json, '$.status_sha256')
            AND json_extract(
                executor_start_failure_receipt_json, '$.status_response.failure_class'
            ) = json_extract(executor_start_failure_receipt_json, '$.failure_class')
            AND json_extract(
                executor_start_failure_receipt_json, '$.status_response.started_at'
            ) IS NULL
            AND json_extract(
                executor_start_failure_receipt_json, '$.status_response.claimed_at'
            ) IS claimed_at
            AND typeof(executor_start_failure_receipt_sha256) = 'text'
            AND length(executor_start_failure_receipt_sha256) = 64
            AND executor_start_failure_receipt_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ), 0)),
    CHECK (
        executor_start_receipt_sha256 IS NULL
        OR executor_start_failure_receipt_sha256 IS NULL
    ),
    CHECK (
        legacy_migrated = 1
        OR executor_configuration_revision IS NULL
        OR started_at IS NULL
        OR executor_start_receipt_sha256 IS NOT NULL
    ),
    CHECK (COALESCE((
        (
            executor_lifecycle_owner_instance_id IS NULL
            AND executor_lifecycle_owner_epoch IS NULL
            AND executor_lifecycle_owner_acquired_at IS NULL
            AND executor_lifecycle_owner_expires_at IS NULL
            AND executor_lifecycle_owner_sha256 IS NULL
        )
        OR (
            legacy_migrated = 0
            AND state IN ('started', 'running', 'completed', 'failed', 'cancelled', 'unknown')
            AND claimed_host_instance_id = target_host_instance_id
            AND typeof(started_at) = 'text'
            AND length(trim(started_at)) > 0
            AND typeof(workspace_ref) = 'text'
            AND length(trim(workspace_ref)) > 0
            AND executor_start_receipt_sha256 IS NOT NULL
            AND typeof(executor_lifecycle_owner_instance_id) = 'text'
            AND length(trim(executor_lifecycle_owner_instance_id)) > 0
            AND typeof(executor_lifecycle_owner_epoch) = 'integer'
            AND executor_lifecycle_owner_epoch > 0
            AND typeof(executor_lifecycle_owner_acquired_at) = 'text'
            AND length(trim(executor_lifecycle_owner_acquired_at)) > 0
            AND typeof(executor_lifecycle_owner_expires_at) = 'text'
            AND length(trim(executor_lifecycle_owner_expires_at)) > 0
            AND typeof(executor_lifecycle_owner_sha256) = 'text'
            AND length(executor_lifecycle_owner_sha256) = 64
            AND executor_lifecycle_owner_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ), 0)),
    CHECK (COALESCE((
        (
            executor_stop_pending_json IS NULL
            AND executor_stop_pending_sha256 IS NULL
        )
        OR (
            legacy_migrated = 0
            AND state IN ('claimed', 'started', 'running')
            AND typeof(executor_stop_pending_json) = 'text'
            AND length(executor_stop_pending_json) <= 32768
            AND json_valid(executor_stop_pending_json)
            AND json_type(executor_stop_pending_json) = 'object'
            AND json_extract(executor_stop_pending_json, '$.schema_version') = 1
            AND json_extract(executor_stop_pending_json, '$.assignment_id') = assignment_id
            AND json_extract(executor_stop_pending_json, '$.fencing_epoch') = fencing_epoch
            AND json_extract(
                executor_stop_pending_json, '$.offer_request_sha256'
            ) = request_sha256
            AND json_extract(
                executor_stop_pending_json, '$.claim_receipt_sha256'
            ) = claim_receipt_sha256
            AND json_extract(
                executor_stop_pending_json, '$.executor_configuration_revision'
            ) = executor_configuration_revision
            AND json_extract(
                executor_stop_pending_json, '$.executor_checkout_path'
            ) = executor_checkout_path
            AND json_extract(
                executor_stop_pending_json, '$.authority_kind'
            ) IN ('start', 'pre_permit', 'lifecycle')
            AND typeof(json_extract(
                executor_stop_pending_json, '$.authority_sha256'
            )) = 'text'
            AND length(json_extract(
                executor_stop_pending_json, '$.authority_sha256'
            )) = 64
            AND json_extract(
                executor_stop_pending_json, '$.authority_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND typeof(json_extract(
                executor_stop_pending_json, '$.session_id'
            )) = 'text'
            AND length(trim(json_extract(
                executor_stop_pending_json, '$.session_id'
            ))) > 0
            AND typeof(json_extract(
                executor_stop_pending_json, '$.run_id'
            )) = 'text'
            AND length(trim(json_extract(
                executor_stop_pending_json, '$.run_id'
            ))) > 0
            AND typeof(json_extract(
                executor_stop_pending_json, '$.project_dir'
            )) = 'text'
            AND length(trim(json_extract(
                executor_stop_pending_json, '$.project_dir'
            ))) > 0
            AND typeof(json_extract(
                executor_stop_pending_json, '$.observed_launch_sha256'
            )) = 'text'
            AND length(json_extract(
                executor_stop_pending_json, '$.observed_launch_sha256'
            )) = 64
            AND json_extract(
                executor_stop_pending_json, '$.observed_launch_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND json_extract(executor_stop_pending_json, '$.reason') IN (
                'start_evidence_invalid', 'start_adoption_fence_lost',
                'start_adoption_failed', 'lifecycle_evidence_invalid'
            )
            AND (
                (
                    json_extract(
                        executor_stop_pending_json, '$.authority_kind'
                    ) = 'start'
                    AND state = 'claimed'
                    AND json_type(
                        executor_stop_pending_json, '$.start_receipt_sha256'
                    ) = 'null'
                    AND json_extract(
                        executor_stop_pending_json, '$.authority_sha256'
                    ) = executor_start_io_permit_sha256
                )
                OR (
                    json_extract(
                        executor_stop_pending_json, '$.authority_kind'
                    ) = 'pre_permit'
                    AND state = 'claimed'
                    AND json_type(
                        executor_stop_pending_json, '$.start_receipt_sha256'
                    ) = 'null'
                    AND executor_start_io_permit_sha256 IS NULL
                    AND json_extract(
                        executor_stop_pending_json, '$.authority_sha256'
                    ) = executor_start_authority_sha256
                )
                OR (
                    json_extract(
                        executor_stop_pending_json, '$.authority_kind'
                    ) = 'lifecycle'
                    AND state IN ('started', 'running')
                    AND json_extract(
                        executor_stop_pending_json, '$.start_receipt_sha256'
                    ) = executor_start_receipt_sha256
                    AND json_extract(
                        executor_stop_pending_json, '$.authority_sha256'
                    ) = executor_lifecycle_owner_sha256
                )
            )
            AND typeof(executor_stop_pending_sha256) = 'text'
            AND length(executor_stop_pending_sha256) = 64
            AND executor_stop_pending_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ), 0)),
    CHECK (COALESCE((
        lease_id IS NULL
        OR (typeof(lease_id) = 'text' AND length(trim(lease_id)) > 0)
    ), 0)),
    CHECK (COALESCE((
        (
            claim_request_sha256 IS NULL
            AND claim_response_json IS NULL
            AND claim_receipt_sha256 IS NULL
        )
        OR (
            legacy_migrated = 0
            AND claimed_at IS NOT NULL
            AND typeof(claim_request_sha256) = 'text'
            AND length(claim_request_sha256) = 64
            AND claim_request_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(claim_response_json) = 'text'
            AND length(claim_response_json) <= 16384
            AND json_valid(claim_response_json)
            AND json_type(claim_response_json) = 'object'
            AND json_extract(claim_response_json, '$.schema_version') = 1
            AND json_extract(claim_response_json, '$.binding.assignment_id') = assignment_id
            AND json_extract(claim_response_json, '$.binding.execution_id') = execution_id
            AND json_extract(claim_response_json, '$.binding.phase') = phase
            AND json_extract(claim_response_json, '$.binding.action_key') = action_key
            AND json_extract(claim_response_json, '$.binding.attempt') = attempt
            AND json_extract(claim_response_json, '$.binding.idempotency_key') = idempotency_key
            AND json_extract(claim_response_json, '$.binding.host_id') = host_id
            AND json_extract(claim_response_json, '$.binding.host_instance_id') = target_host_instance_id
            AND json_extract(claim_response_json, '$.binding.fencing_epoch') = fencing_epoch
            AND json_extract(claim_response_json, '$.binding.configuration_revision') = configuration_revision
            AND json_extract(claim_response_json, '$.binding.execution_record_sha256') = execution_record_sha256
            AND json_extract(claim_response_json, '$.offer_request_sha256') = request_sha256
            AND json_extract(claim_response_json, '$.claimed_at') = claimed_at
            AND typeof(json_extract(claim_response_json, '$.lease.lease_id')) = 'text'
            AND length(trim(json_extract(claim_response_json, '$.lease.lease_id'))) > 0
            AND typeof(json_extract(claim_response_json, '$.lease.expires_at')) = 'text'
            AND length(trim(json_extract(claim_response_json, '$.lease.expires_at'))) > 0
            AND typeof(claim_receipt_sha256) = 'text'
            AND length(claim_receipt_sha256) = 64
            AND claim_receipt_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ), 0)),
    CHECK (
        legacy_migrated = 1
        OR claimed_at IS NULL
        OR claim_receipt_sha256 IS NOT NULL
    ),
    CHECK (COALESCE((
        (
            controller_lifecycle_trust_json IS NULL
            AND controller_lifecycle_trust_sha256 IS NULL
        )
        OR (
            legacy_migrated = 0
            AND typeof(controller_lifecycle_trust_json) = 'text'
            AND length(controller_lifecycle_trust_json) <= 4096
            AND json_valid(controller_lifecycle_trust_json)
            AND json_type(controller_lifecycle_trust_json) = 'object'
            AND json_extract(controller_lifecycle_trust_json, '$.schema_version') = 1
            AND json_extract(controller_lifecycle_trust_json, '$.host_id') = host_id
            AND json_extract(
                controller_lifecycle_trust_json, '$.configuration_revision'
            ) = configuration_revision
            AND json_extract(
                controller_lifecycle_trust_json, '$.observed_host_instance_id'
            ) = target_host_instance_id
            AND typeof(json_extract(
                controller_lifecycle_trust_json, '$.endpoint'
            )) = 'text'
            AND length(trim(json_extract(
                controller_lifecycle_trust_json, '$.endpoint'
            ))) > 0
            AND typeof(json_extract(
                controller_lifecycle_trust_json, '$.certificate_spki_pin'
            )) = 'text'
            AND typeof(json_extract(
                controller_lifecycle_trust_json, '$.credential_reference_sha256'
            )) = 'text'
            AND length(json_extract(
                controller_lifecycle_trust_json, '$.credential_reference_sha256'
            )) = 64
            AND json_extract(
                controller_lifecycle_trust_json, '$.credential_reference_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND typeof(json_extract(
                controller_lifecycle_trust_json, '$.advertisement_sha256'
            )) = 'text'
            AND length(json_extract(
                controller_lifecycle_trust_json, '$.advertisement_sha256'
            )) = 64
            AND json_extract(
                controller_lifecycle_trust_json, '$.advertisement_sha256'
            ) NOT GLOB '*[^0-9a-f]*'
            AND typeof(controller_lifecycle_trust_sha256) = 'text'
            AND length(controller_lifecycle_trust_sha256) = 64
            AND controller_lifecycle_trust_sha256 NOT GLOB '*[^0-9a-f]*'
            AND json_extract(
                controller_lifecycle_trust_json, '$.snapshot_sha256'
            ) = controller_lifecycle_trust_sha256
        )
    ), 0)),
    CHECK (COALESCE((
        (
            controller_operation_kind IS NULL
            AND controller_operation_request_sha256 IS NULL
            AND controller_operation_trust_sha256 IS NULL
            AND controller_operation_fence_json IS NULL
            AND controller_operation_fence_sha256 IS NULL
        )
        OR (
            controller_operation_kind IN (
                'upload_source_bundle', 'offer', 'claim', 'renew', 'status',
                'cancel', 'settle', 'fetch_artifact', 'observe_cleanup'
            )
            AND typeof(controller_operation_request_sha256) = 'text'
            AND length(controller_operation_request_sha256) = 64
            AND controller_operation_request_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(controller_operation_trust_sha256) = 'text'
            AND length(controller_operation_trust_sha256) = 64
            AND controller_operation_trust_sha256 NOT GLOB '*[^0-9a-f]*'
            AND controller_lifecycle_trust_json IS NOT NULL
                    AND typeof(controller_operation_fence_json) = 'text'
                    AND length(controller_operation_fence_json) <= 4096
                    AND json_valid(controller_operation_fence_json)
                    AND json_type(controller_operation_fence_json) = 'object'
                    AND json_extract(
                        controller_operation_fence_json, '$.schema_version'
                    ) = 1
                    AND json_extract(
                        controller_operation_fence_json, '$.host_id'
                    ) = host_id
                    AND json_extract(
                        controller_operation_fence_json, '$.endpoint'
                    ) = json_extract(
                        controller_lifecycle_trust_json, '$.endpoint'
                    )
                    AND json_extract(
                        controller_operation_fence_json, '$.certificate_spki_pin'
                    ) = json_extract(
                        controller_lifecycle_trust_json, '$.certificate_spki_pin'
                    )
                    AND json_extract(
                        controller_operation_fence_json, '$.credential_reference_sha256'
                    ) = json_extract(
                        controller_lifecycle_trust_json, '$.credential_reference_sha256'
                    )
                    AND typeof(json_extract(
                        controller_operation_fence_json, '$.advertisement_sha256'
                    )) = 'text'
                    AND length(json_extract(
                        controller_operation_fence_json, '$.advertisement_sha256'
                    )) = 64
                    AND json_extract(
                        controller_operation_fence_json, '$.advertisement_sha256'
                    ) NOT GLOB '*[^0-9a-f]*'
                    AND (
                        (
                            controller_operation_kind IN (
                                'upload_source_bundle', 'offer', 'claim', 'renew'
                            )
                            AND json_extract(
                                controller_operation_fence_json,
                                '$.configuration_revision'
                            ) = configuration_revision
                            AND json_extract(
                                controller_operation_fence_json,
                                '$.observed_host_instance_id'
                            ) = target_host_instance_id
                            AND json_extract(
                                controller_operation_fence_json,
                                '$.enabled_at_capture'
                            ) = 1
                        )
                        OR (
                            controller_operation_kind IN (
                                'status', 'cancel', 'settle', 'fetch_artifact',
                                'observe_cleanup'
                            )
                            AND json_extract(
                                controller_operation_fence_json,
                                '$.configuration_revision'
                            ) >= configuration_revision
                            AND typeof(json_extract(
                                controller_operation_fence_json,
                                '$.observed_host_instance_id'
                            )) = 'text'
                            AND length(trim(json_extract(
                                controller_operation_fence_json,
                                '$.observed_host_instance_id'
                            ))) > 0
                        )
                    )
                    AND typeof(controller_operation_fence_sha256) = 'text'
                    AND length(controller_operation_fence_sha256) = 64
                    AND controller_operation_fence_sha256 NOT GLOB '*[^0-9a-f]*'
                    AND json_extract(
                        controller_operation_fence_json, '$.snapshot_sha256'
                    ) = controller_operation_fence_sha256
        )
    ), 0)),
    CHECK (COALESCE((
        (last_mutation_kind IS NULL AND last_mutation_sha256 IS NULL)
        OR (
            last_mutation_kind IN (
                'claim', 'renew', 'cancel', 'settle',
                'claim_response', 'renew_response', 'cancel_response'
            )
            AND typeof(last_mutation_sha256) = 'text'
            AND length(last_mutation_sha256) = 64
            AND last_mutation_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ), 0)),
    CHECK (legacy_migrated = 1 OR error IS NOT 'executor_unavailable'),
    CHECK (COALESCE((
        (
            executor_configuration_revision IS NULL
            AND executor_checkout_path IS NULL
        )
        OR (
            typeof(executor_configuration_revision) = 'integer'
            AND executor_configuration_revision > 0
            AND typeof(executor_checkout_path) = 'text'
            AND executor_checkout_path = trim(executor_checkout_path)
            AND length(executor_checkout_path) > 1
            AND substr(executor_checkout_path, 1, 1) = '/'
        )
    ), 0)),
    CHECK (COALESCE((
        (
            executor_start_authority_sha256 IS NULL
            AND executor_start_authority_at IS NULL
        )
        OR (
            legacy_migrated = 0
            AND state = 'claimed'
            AND claimed_host_instance_id = target_host_instance_id
            AND typeof(executor_configuration_revision) = 'integer'
            AND typeof(executor_checkout_path) = 'text'
            AND started_at IS NULL
            AND workspace_ref IS NULL
            AND executor_start_receipt_json IS NULL
            AND executor_start_receipt_sha256 IS NULL
            AND completed_at IS NULL
            AND result_json IS NULL
            AND status_sha256 IS NULL
            AND result_sha256 IS NULL
            AND cleanup_settlement_request_sha256 IS NULL
            AND cleanup_completed_at IS NULL
            AND typeof(executor_start_authority_sha256) = 'text'
            AND length(executor_start_authority_sha256) = 64
            AND executor_start_authority_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(executor_start_authority_at) = 'text'
            AND length(trim(executor_start_authority_at)) > 0
        )
    ), 0)),
    CHECK (COALESCE((
        (
            executor_start_io_permit_sha256 IS NULL
            AND executor_start_io_permit_at IS NULL
        )
        OR (
            legacy_migrated = 0
            AND state = 'claimed'
            AND executor_start_authority_sha256 IS NOT NULL
            AND executor_start_authority_at IS NOT NULL
            AND executor_start_receipt_json IS NULL
            AND executor_start_receipt_sha256 IS NULL
            AND started_at IS NULL
            AND workspace_ref IS NULL
            AND completed_at IS NULL
            AND typeof(executor_start_io_permit_sha256) = 'text'
            AND length(executor_start_io_permit_sha256) = 64
            AND executor_start_io_permit_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(executor_start_io_permit_at) = 'text'
            AND length(trim(executor_start_io_permit_at)) > 0
        )
    ), 0)),
    CHECK (
        state NOT IN ('claimed', 'started', 'running', 'completed')
        OR (
            claimed_host_instance_id IS NOT NULL
            AND lease_id IS NOT NULL
            AND typeof(claimed_at) = 'text'
            AND length(trim(claimed_at)) > 0
        )
    ),
    CHECK (
        state NOT IN ('started', 'running', 'completed')
        OR (
            typeof(started_at) = 'text'
            AND length(trim(started_at)) > 0
            AND typeof(workspace_ref) = 'text'
            AND length(trim(workspace_ref)) > 0
        )
    ),
    CHECK (COALESCE((
        legacy_migrated = 1
        OR (result_json IS NULL AND status_sha256 IS NULL AND result_sha256 IS NULL)
        OR (
            typeof(result_json) = 'text'
            AND json_valid(result_json)
            AND json_type(result_json) = 'object'
            AND json_extract(result_json, '$.schema_version') = 1
            AND json_extract(result_json, '$.binding.assignment_id') = assignment_id
            AND json_extract(result_json, '$.binding.execution_id') = execution_id
            AND json_extract(result_json, '$.binding.phase') = phase
            AND json_extract(result_json, '$.binding.action_key') = action_key
            AND json_extract(result_json, '$.binding.attempt') = attempt
            AND json_extract(result_json, '$.binding.idempotency_key') = idempotency_key
            AND json_extract(result_json, '$.binding.host_id') = host_id
            AND json_extract(result_json, '$.binding.host_instance_id') = target_host_instance_id
            AND json_extract(result_json, '$.binding.fencing_epoch') = fencing_epoch
            AND json_extract(result_json, '$.binding.configuration_revision') = configuration_revision
            AND json_extract(result_json, '$.binding.execution_record_sha256') = execution_record_sha256
            AND json_extract(result_json, '$.offer_request_sha256') = request_sha256
            AND json_extract(result_json, '$.state') = state
            AND (
                (
                    state = 'failed'
                    AND json_type(result_json, '$.failure_class') = 'text'
                    AND json_extract(result_json, '$.failure_class') IN (
                        'transient', 'permanent', 'authentication',
                        'configuration', 'policy', 'conflict'
                    )
                )
                OR (
                    state != 'failed'
                    AND json_type(result_json, '$.failure_class') IS NULL
                )
            )
            AND typeof(status_sha256) = 'text'
            AND length(status_sha256) = 64
            AND status_sha256 NOT GLOB '*[^0-9a-f]*'
            AND json_extract(result_json, '$.status_sha256') = status_sha256
            AND json_extract(result_json, '$.claimed_at') IS claimed_at
            AND json_extract(result_json, '$.started_at') IS started_at
            AND json_extract(result_json, '$.workspace_ref') IS workspace_ref
            AND (
                (
                    state = 'completed'
                    AND typeof(result_sha256) = 'text'
                    AND length(result_sha256) = 64
                    AND result_sha256 NOT GLOB '*[^0-9a-f]*'
                    AND json_extract(result_json, '$.result.result_sha256') = result_sha256
                    AND json_extract(result_json, '$.result.offer_request_sha256') = request_sha256
                    AND json_extract(result_json, '$.result.result.execution_id') = execution_id
                    AND json_extract(result_json, '$.result.result.action_key') = action_key
                    AND json_extract(result_json, '$.result.result.attempt') = attempt
                    AND json_extract(result_json, '$.result.result.idempotency_key') = idempotency_key
                )
                OR (
                    state IN (
                        'offered', 'claimed', 'running', 'failed',
                        'cancelled', 'superseded', 'unknown'
                    )
                    AND result_sha256 IS NULL
                    AND json_extract(result_json, '$.result') IS NULL
                    AND json_type(result_json, '$.output_artifacts') = 'object'
                    AND (
                        json_type(result_json, '$.output_artifacts.entries') IS NULL
                        OR (
                            json_type(result_json, '$.output_artifacts.entries') = 'array'
                            AND json_array_length(
                                result_json, '$.output_artifacts.entries'
                            ) = 0
                        )
                    )
                )
            )
        )
    ), 0)),
    CHECK (state != 'completed' OR (result_json IS NOT NULL AND result_sha256 IS NOT NULL)),
    CHECK (COALESCE((
        (
            cleanup_settlement_request_sha256 IS NULL
            AND cleanup_completed_at IS NULL
        )
        OR (
            legacy_migrated = 0
            AND state IN ('completed', 'failed', 'cancelled', 'superseded', 'unknown')
            AND typeof(cleanup_settlement_request_sha256) = 'text'
            AND length(cleanup_settlement_request_sha256) = 64
            AND cleanup_settlement_request_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(cleanup_completed_at) = 'text'
            AND length(trim(cleanup_completed_at)) > 0
        )
    ), 0)),
    CHECK (COALESCE((
        (
            controller_handoff_kind IS NULL
            AND controller_handoff_execution_sha256 IS NULL
            AND controller_handoff_successor_assignment_id IS NULL
            AND controller_handoff_successor_fencing_epoch IS NULL
            AND controller_handoff_at IS NULL
        )
        OR (
            legacy_migrated = 0
            AND (
                (
                    controller_handoff_kind = 'local_fallback'
                    AND state = 'superseded'
                    AND controller_handoff_successor_assignment_id IS NULL
                    AND controller_handoff_successor_fencing_epoch IS NULL
                )
                OR (
                    controller_handoff_kind = 'remote_reassigned'
                    AND state = 'superseded'
                    AND typeof(controller_handoff_successor_assignment_id) = 'text'
                    AND length(trim(controller_handoff_successor_assignment_id)) > 0
                    AND typeof(controller_handoff_successor_fencing_epoch) = 'integer'
                    AND controller_handoff_successor_fencing_epoch > fencing_epoch
                )
                OR (
                    controller_handoff_kind = 'result_adopted'
                    AND state IN ('completed', 'failed')
                    AND controller_handoff_successor_assignment_id IS NULL
                    AND controller_handoff_successor_fencing_epoch IS NULL
                )
                OR (
                    controller_handoff_kind = 'evidence_only'
                    AND state IN ('completed', 'failed', 'cancelled', 'unknown')
                    AND controller_handoff_successor_assignment_id IS NULL
                    AND controller_handoff_successor_fencing_epoch IS NULL
                )
                OR (
                    controller_handoff_kind = 'terminal_projection'
                    AND state IN ('completed', 'failed', 'cancelled')
                    AND controller_handoff_successor_assignment_id IS NULL
                    AND controller_handoff_successor_fencing_epoch IS NULL
                )
                OR (
                    controller_handoff_kind = 'terminal_cleanup'
                    AND state IN ('completed', 'failed', 'cancelled', 'superseded', 'unknown')
                    AND controller_handoff_successor_assignment_id IS NULL
                    AND controller_handoff_successor_fencing_epoch IS NULL
                )
            )
            AND typeof(controller_handoff_execution_sha256) = 'text'
            AND length(controller_handoff_execution_sha256) = 64
            AND controller_handoff_execution_sha256 NOT GLOB '*[^0-9a-f]*'
            AND typeof(controller_handoff_at) = 'text'
            AND length(trim(controller_handoff_at)) > 0
        )
    ), 0)),
    CHECK (
        state NOT IN ('completed', 'failed', 'cancelled', 'superseded')
        OR (typeof(completed_at) = 'text' AND length(trim(completed_at)) > 0)
    )
) WITHOUT ROWID;

INSERT INTO task_board_remote_assignments (
    assignment_id,
    execution_id,
    phase,
    action_key,
    attempt,
    idempotency_key,
    host_id,
    target_host_instance_id,
    claimed_host_instance_id,
    lease_id,
    fencing_epoch,
    configuration_revision,
    execution_record_sha256,
    request_sha256,
    request_json,
    authenticated_principal,
    claim_request_sha256,
    claim_response_json,
    claim_receipt_sha256,
    controller_operation_kind,
    controller_operation_request_sha256,
    controller_operation_trust_sha256,
    last_mutation_kind,
    last_mutation_sha256,
    state,
    legacy_migrated,
    offered_at,
    claimed_at,
    started_at,
    heartbeat_at,
    lease_expires_at,
    deadline_at,
    cancel_requested_at,
    completed_at,
    workspace_ref,
    executor_configuration_revision,
    executor_checkout_path,
    executor_start_authority_sha256,
    executor_start_authority_at,
    executor_start_io_permit_sha256,
    executor_start_io_permit_at,
    executor_start_receipt_json,
    executor_start_receipt_sha256,
    executor_lifecycle_owner_instance_id,
    executor_lifecycle_owner_epoch,
    executor_lifecycle_owner_acquired_at,
    executor_lifecycle_owner_expires_at,
    executor_lifecycle_owner_sha256,
    executor_stop_pending_json,
    executor_stop_pending_sha256,
    result_json,
    status_sha256,
    result_sha256,
    cleanup_settlement_request_sha256,
    cleanup_completed_at,
    error,
    updated_at
)
SELECT
    assignment_id,
    execution_id,
    phase,
    NULL,
    NULL,
    idempotency_key,
    host_id,
    NULL,
    NULL,
    NULL,
    fencing_epoch,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'superseded',
    1,
    offered_at,
    acknowledged_at,
    started_at,
    heartbeat_at,
    NULL,
    NULL,
    NULL,
    COALESCE(completed_at, heartbeat_at, started_at, acknowledged_at, offered_at),
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    result_json,
    NULL,
    NULL,
    NULL,
    NULL,
    COALESCE(error, 'migrated from dormant v36 assignment; never executable'),
    COALESCE(completed_at, heartbeat_at, started_at, acknowledged_at, offered_at)
FROM task_board_remote_assignments_v36;

DROP TABLE task_board_remote_assignments_v36;
DROP TABLE task_board_execution_hosts_v36;
DROP TABLE task_board_remote_v43_guard;

-- Child evidence binds the assignment id and fencing generation as one parent
-- key. This prevents replay lookup from accepting a receipt or blob whose id
-- matches while its generation no longer does.
CREATE UNIQUE INDEX task_board_remote_assignments_identity_epoch
    ON task_board_remote_assignments(assignment_id, fencing_epoch);

-- Executor-local immutable offer receipt. This ledger deliberately has no host
-- foreign key: inserting a fabricated host row for an ineligible offer would
-- turn untrusted request identity into operator-owned configuration. Exact
-- accepted and bounded rejected responses are reconstructed from the sealed
-- request plus the disposition-paired fields below, never mutable assignment
-- lease state or a loose response payload.
CREATE TABLE task_board_remote_offer_receipts (
    assignment_id TEXT PRIMARY KEY CHECK (
        typeof(assignment_id) = 'text'
        AND assignment_id = trim(assignment_id)
        AND length(assignment_id) > 0
    ),
    execution_id TEXT NOT NULL CHECK (
        typeof(execution_id) = 'text'
        AND execution_id = trim(execution_id)
        AND length(execution_id) > 0
    ),
    phase TEXT NOT NULL CHECK (phase IN ('implementation', 'review', 'evaluate')),
    action_key TEXT NOT NULL CHECK (
        typeof(action_key) = 'text'
        AND action_key = trim(action_key)
        AND length(action_key) > 0
    ),
    attempt INTEGER NOT NULL CHECK (typeof(attempt) = 'integer' AND attempt > 0),
    idempotency_key TEXT NOT NULL CHECK (
        typeof(idempotency_key) = 'text'
        AND idempotency_key = trim(idempotency_key)
        AND length(idempotency_key) > 0
    ),
    host_id TEXT NOT NULL CHECK (
        typeof(host_id) = 'text'
        AND host_id = trim(host_id)
        AND length(host_id) > 0
    ),
    target_host_instance_id TEXT NOT NULL CHECK (
        typeof(target_host_instance_id) = 'text'
        AND target_host_instance_id = trim(target_host_instance_id)
        AND length(target_host_instance_id) > 0
    ),
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    configuration_revision INTEGER NOT NULL CHECK (
        typeof(configuration_revision) = 'integer' AND configuration_revision > 0
    ),
    execution_record_sha256 TEXT NOT NULL CHECK (
        typeof(execution_record_sha256) = 'text'
        AND length(execution_record_sha256) = 64
        AND execution_record_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    request_sha256 TEXT NOT NULL CHECK (
        typeof(request_sha256) = 'text'
        AND length(request_sha256) = 64
        AND request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    request_json TEXT NOT NULL CHECK (COALESCE((
        typeof(request_json) = 'text'
        AND json_valid(request_json)
        AND json_type(request_json) = 'object'
        AND json_extract(request_json, '$.schema_version') = 1
        AND json_extract(request_json, '$.binding.assignment_id') = assignment_id
        AND json_extract(request_json, '$.binding.execution_id') = execution_id
        AND json_extract(request_json, '$.binding.phase') = phase
        AND json_extract(request_json, '$.binding.action_key') = action_key
        AND json_extract(request_json, '$.binding.attempt') = attempt
        AND json_extract(request_json, '$.binding.idempotency_key') = idempotency_key
        AND json_extract(request_json, '$.binding.host_id') = host_id
        AND json_extract(request_json, '$.binding.host_instance_id') = target_host_instance_id
        AND json_extract(request_json, '$.binding.fencing_epoch') = fencing_epoch
        AND json_extract(request_json, '$.binding.configuration_revision') = configuration_revision
        AND json_extract(request_json, '$.binding.execution_record_sha256') = execution_record_sha256
        AND json_extract(request_json, '$.request_sha256') = request_sha256
        AND typeof(json_extract(request_json, '$.deadline_at')) = 'text'
        AND length(trim(json_extract(request_json, '$.deadline_at'))) > 0
    ), 0)),
    authenticated_principal TEXT NOT NULL CHECK (
        typeof(authenticated_principal) = 'text'
        AND authenticated_principal = trim(authenticated_principal)
        AND length(authenticated_principal) > 0
    ),
    disposition TEXT NOT NULL CHECK (disposition IN ('accepted', 'rejected')),
    initial_lease_id TEXT,
    initial_lease_expires_at TEXT,
    rejection_code TEXT,
    received_at TEXT NOT NULL CHECK (
        typeof(received_at) = 'text' AND length(trim(received_at)) > 0
    ),
    CHECK (COALESCE((
        (
            disposition = 'accepted'
            AND typeof(initial_lease_id) = 'text'
            AND initial_lease_id = trim(initial_lease_id)
            AND length(initial_lease_id) > 0
            AND typeof(initial_lease_expires_at) = 'text'
            AND length(trim(initial_lease_expires_at)) > 0
            AND rejection_code IS NULL
        )
        OR (
            disposition = 'rejected'
            AND initial_lease_id IS NULL
            AND initial_lease_expires_at IS NULL
            AND typeof(rejection_code) = 'text'
            AND rejection_code = trim(rejection_code)
            AND length(rejection_code) BETWEEN 1 AND 64
            AND rejection_code NOT GLOB '*[^a-z0-9_]*'
        )
    ), 0))
) WITHOUT ROWID;

-- Executor-local immutable acknowledgement that the controller durably adopted
-- one exact terminal generation. Settlement replay never depends on the
-- assignment's mutable last-mutation marker. The first response and cleanup
-- readiness are one insert; a separate assignment marker records completed
-- cleanup only after this receipt is durable.
CREATE TABLE task_board_remote_settlement_receipts (
    assignment_id TEXT PRIMARY KEY CHECK (
            typeof(assignment_id) = 'text'
            AND assignment_id = trim(assignment_id)
            AND length(assignment_id) > 0
        ),
    execution_id TEXT NOT NULL CHECK (
        typeof(execution_id) = 'text'
        AND execution_id = trim(execution_id)
        AND length(execution_id) > 0
    ),
    phase TEXT NOT NULL CHECK (phase IN ('implementation', 'review', 'evaluate')),
    action_key TEXT NOT NULL CHECK (
        typeof(action_key) = 'text'
        AND action_key = trim(action_key)
        AND length(action_key) > 0
    ),
    attempt INTEGER NOT NULL CHECK (typeof(attempt) = 'integer' AND attempt > 0),
    idempotency_key TEXT NOT NULL CHECK (
        typeof(idempotency_key) = 'text'
        AND idempotency_key = trim(idempotency_key)
        AND length(idempotency_key) > 0
    ),
    host_id TEXT NOT NULL CHECK (
        typeof(host_id) = 'text'
        AND host_id = trim(host_id)
        AND length(host_id) > 0
    ),
    target_host_instance_id TEXT NOT NULL CHECK (
        typeof(target_host_instance_id) = 'text'
        AND target_host_instance_id = trim(target_host_instance_id)
        AND length(target_host_instance_id) > 0
    ),
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    configuration_revision INTEGER NOT NULL CHECK (
        typeof(configuration_revision) = 'integer' AND configuration_revision > 0
    ),
    execution_record_sha256 TEXT NOT NULL CHECK (
        typeof(execution_record_sha256) = 'text'
        AND length(execution_record_sha256) = 64
        AND execution_record_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    lease_id TEXT NOT NULL CHECK (
        typeof(lease_id) = 'text'
        AND lease_id = trim(lease_id)
        AND length(lease_id) > 0
    ),
    offer_request_sha256 TEXT NOT NULL CHECK (
        typeof(offer_request_sha256) = 'text'
        AND length(offer_request_sha256) = 64
        AND offer_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    terminal_state TEXT NOT NULL CHECK (
        terminal_state IN ('completed', 'failed', 'cancelled', 'superseded', 'unknown')
    ),
    result_sha256 TEXT CHECK (
        result_sha256 IS NULL
        OR (
            typeof(result_sha256) = 'text'
            AND length(result_sha256) = 64
            AND result_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ),
    request_sha256 TEXT NOT NULL CHECK (
        typeof(request_sha256) = 'text'
        AND length(request_sha256) = 64
        AND request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    request_json TEXT NOT NULL CHECK (COALESCE((
        typeof(request_json) = 'text'
        AND json_valid(request_json)
        AND json_type(request_json) = 'object'
        AND json_extract(request_json, '$.schema_version') = 1
        AND json_extract(request_json, '$.binding.assignment_id') = assignment_id
        AND json_extract(request_json, '$.binding.execution_id') = execution_id
        AND json_extract(request_json, '$.binding.phase') = phase
        AND json_extract(request_json, '$.binding.action_key') = action_key
        AND json_extract(request_json, '$.binding.attempt') = attempt
        AND json_extract(request_json, '$.binding.idempotency_key') = idempotency_key
        AND json_extract(request_json, '$.binding.host_id') = host_id
        AND json_extract(request_json, '$.binding.host_instance_id') = target_host_instance_id
        AND json_extract(request_json, '$.binding.fencing_epoch') = fencing_epoch
        AND json_extract(request_json, '$.binding.configuration_revision') = configuration_revision
        AND json_extract(request_json, '$.binding.execution_record_sha256') = execution_record_sha256
        AND json_extract(request_json, '$.lease_id') = lease_id
        AND json_extract(request_json, '$.offer_request_sha256') = offer_request_sha256
        AND json_extract(request_json, '$.terminal_state') = terminal_state
        AND json_extract(request_json, '$.result_sha256') IS result_sha256
        AND json_extract(request_json, '$.request_sha256') = request_sha256
    ), 0)),
    authenticated_principal TEXT NOT NULL CHECK (
        typeof(authenticated_principal) = 'text'
        AND authenticated_principal = trim(authenticated_principal)
        AND length(authenticated_principal) > 0
    ),
    response_json TEXT NOT NULL CHECK (COALESCE((
        typeof(response_json) = 'text'
        AND length(response_json) BETWEEN 1 AND 16384
        AND json_valid(response_json)
        AND json_type(response_json) = 'object'
        AND json_extract(response_json, '$.schema_version') = 1
        AND json_extract(response_json, '$.binding') = json_extract(request_json, '$.binding')
        AND json_extract(response_json, '$.offer_request_sha256') = offer_request_sha256
        AND json_extract(response_json, '$.settlement_request_sha256') = request_sha256
        AND json_extract(response_json, '$.settled_at') = settled_at
    ), 0)),
    settled_at TEXT NOT NULL CHECK (
        typeof(settled_at) = 'text' AND length(trim(settled_at)) > 0
    ),
    cleanup_ready_at TEXT NOT NULL CHECK (
        typeof(cleanup_ready_at) = 'text'
        AND cleanup_ready_at = settled_at
    ),
    CHECK (
        (terminal_state = 'completed' AND result_sha256 IS NOT NULL)
        OR (terminal_state != 'completed' AND result_sha256 IS NULL)
    ),
    FOREIGN KEY (assignment_id, fencing_epoch)
        REFERENCES task_board_remote_assignments(assignment_id, fencing_epoch)
        ON DELETE CASCADE
) WITHOUT ROWID;

-- Controller-to-executor source bytes are uploaded before an offer can be
-- accepted. The immutable receipt deliberately has no assignment foreign key:
-- the assignment is created only after this exact generation is durable.
CREATE TABLE task_board_remote_source_bundles (
    assignment_id TEXT NOT NULL CHECK (
        typeof(assignment_id) = 'text'
        AND assignment_id = trim(assignment_id)
        AND length(assignment_id) > 0
    ),
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    execution_id TEXT NOT NULL CHECK (
        typeof(execution_id) = 'text'
        AND execution_id = trim(execution_id)
        AND length(execution_id) > 0
    ),
    action_key TEXT NOT NULL CHECK (
        typeof(action_key) = 'text'
        AND action_key = trim(action_key)
        AND length(action_key) > 0
    ),
    attempt INTEGER NOT NULL CHECK (typeof(attempt) = 'integer' AND attempt > 0),
    idempotency_key TEXT NOT NULL CHECK (
        typeof(idempotency_key) = 'text'
        AND idempotency_key = trim(idempotency_key)
        AND length(idempotency_key) > 0
    ),
    host_id TEXT NOT NULL CHECK (
        typeof(host_id) = 'text' AND host_id = trim(host_id) AND length(host_id) > 0
    ),
    target_host_instance_id TEXT NOT NULL CHECK (
        typeof(target_host_instance_id) = 'text'
        AND target_host_instance_id = trim(target_host_instance_id)
        AND length(target_host_instance_id) > 0
    ),
    offer_request_sha256 TEXT NOT NULL CHECK (
        typeof(offer_request_sha256) = 'text'
        AND length(offer_request_sha256) = 64
        AND offer_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    offer_json TEXT NOT NULL CHECK (COALESCE((
        typeof(offer_json) = 'text'
        AND length(offer_json) BETWEEN 1 AND 16777216
        AND json_valid(offer_json)
        AND json_type(offer_json) = 'object'
        AND json_extract(offer_json, '$.binding.assignment_id') = assignment_id
        AND json_extract(offer_json, '$.binding.execution_id') = execution_id
        AND json_extract(offer_json, '$.binding.action_key') = action_key
        AND json_extract(offer_json, '$.binding.attempt') = attempt
        AND json_extract(offer_json, '$.binding.idempotency_key') = idempotency_key
        AND json_extract(offer_json, '$.binding.host_id') = host_id
        AND json_extract(offer_json, '$.binding.host_instance_id') = target_host_instance_id
        AND json_extract(offer_json, '$.binding.fencing_epoch') = fencing_epoch
        AND json_extract(offer_json, '$.request_sha256') = offer_request_sha256
        AND json_extract(offer_json, '$.source.kind') = source_kind
        AND json_extract(offer_json, '$.source.repository')
            = json_extract(offer_json, '$.binding.repository')
        AND json_extract(offer_json, '$.source.revision') = result_revision
        AND json_extract(offer_json, '$.source.advertised_ref') = advertised_ref
        AND json_extract(offer_json, '$.source.bundle.relative_path') = relative_path
        AND json_extract(offer_json, '$.source.bundle.sha256') = sha256
        AND json_extract(offer_json, '$.source.bundle.size_bytes') = size_bytes
        AND json_extract(offer_json, '$.source.bundle.media_type') = media_type
        AND (
            (
                source_kind = 'prior_phase_bundle'
                AND json_extract(offer_json, '$.source.base_revision') = base_revision
            )
            OR (
                source_kind = 'repository_snapshot_bundle'
                AND json_type(offer_json, '$.source.base_revision') IS NULL
                AND base_revision = result_revision
            )
        )
    ), 0)),
    upload_request_sha256 TEXT NOT NULL CHECK (
        typeof(upload_request_sha256) = 'text'
        AND length(upload_request_sha256) = 64
        AND upload_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    authenticated_principal TEXT NOT NULL CHECK (
        typeof(authenticated_principal) = 'text'
        AND authenticated_principal = trim(authenticated_principal)
        AND length(authenticated_principal) BETWEEN 1 AND 256
    ),
    source_kind TEXT NOT NULL CHECK (
        typeof(source_kind) = 'text'
        AND source_kind IN ('prior_phase_bundle', 'repository_snapshot_bundle')
    ),
    base_revision TEXT NOT NULL CHECK (
        typeof(base_revision) = 'text'
        AND length(base_revision) IN (40, 64)
        AND base_revision NOT GLOB '*[^0-9a-f]*'
    ),
    result_revision TEXT NOT NULL CHECK (
        typeof(result_revision) = 'text'
        AND length(result_revision) = length(base_revision)
        AND result_revision NOT GLOB '*[^0-9a-f]*'
    ),
    advertised_ref TEXT NOT NULL CHECK (
        typeof(advertised_ref) = 'text'
    ),
    relative_path TEXT NOT NULL CHECK (
        typeof(relative_path) = 'text'
        AND length(relative_path) BETWEEN 1 AND 512
        AND substr(relative_path, 1, 1) != '/'
        AND instr(relative_path, char(0)) = 0
        AND instr(relative_path, char(92)) = 0
        AND relative_path NOT GLOB '*[^A-Za-z0-9._/-]*'
    ),
    sha256 TEXT NOT NULL CHECK (
        typeof(sha256) = 'text'
        AND length(sha256) = 64
        AND sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    size_bytes INTEGER NOT NULL CHECK (
        typeof(size_bytes) = 'integer' AND size_bytes BETWEEN 1 AND 33554432
    ),
    media_type TEXT NOT NULL CHECK (
        typeof(media_type) = 'text' AND media_type = 'application/x-git-bundle'
    ),
    content BLOB NOT NULL CHECK (typeof(content) = 'blob'),
    content_pruned_at TEXT,
    response_json TEXT NOT NULL CHECK (COALESCE((
        typeof(response_json) = 'text'
        AND length(response_json) BETWEEN 1 AND 16384
        AND json_valid(response_json)
        AND json_type(response_json) = 'object'
        AND json_extract(response_json, '$.schema_version') = 1
        AND json_extract(response_json, '$.binding') = json_extract(offer_json, '$.binding')
        AND json_extract(response_json, '$.offer_request_sha256') = offer_request_sha256
        AND json_extract(response_json, '$.upload_request_sha256') = upload_request_sha256
        AND json_extract(response_json, '$.artifact.relative_path') = relative_path
        AND json_extract(response_json, '$.artifact.sha256') = sha256
        AND json_extract(response_json, '$.artifact.size_bytes') = size_bytes
        AND json_extract(response_json, '$.artifact.media_type') = media_type
        AND json_extract(response_json, '$.stored_at') = stored_at
    ), 0)),
    stored_at TEXT NOT NULL CHECK (
        typeof(stored_at) = 'text' AND length(trim(stored_at)) > 0
    ),
    CHECK (
        (
            source_kind = 'prior_phase_bundle'
            AND result_revision != base_revision
            AND advertised_ref = 'refs/harness/task-board/results/' || result_revision
        )
        OR (
            source_kind = 'repository_snapshot_bundle'
            AND result_revision = base_revision
            AND advertised_ref = 'refs/harness/task-board/sources/' || result_revision
        )
    ),
    CHECK (
        (content_pruned_at IS NULL AND length(content) = size_bytes)
        OR (
            content_pruned_at IS NOT NULL
            AND typeof(content_pruned_at) = 'text'
            AND length(trim(content_pruned_at)) > 0
            AND length(content) = 0
        )
    ),
    PRIMARY KEY (assignment_id, fencing_epoch)
) WITHOUT ROWID;

-- Controller-owned portable source bytes are committed atomically with the
-- exact offered assignment. They survive controller restarts and host
-- reassignment without reading a later-mutated local worktree.
CREATE TABLE task_board_remote_outbound_sources (
    assignment_id TEXT NOT NULL CHECK (
        typeof(assignment_id) = 'text'
        AND assignment_id = trim(assignment_id)
        AND length(assignment_id) BETWEEN 1 AND 256
    ),
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    execution_id TEXT NOT NULL CHECK (
        typeof(execution_id) = 'text'
        AND execution_id = trim(execution_id)
        AND length(execution_id) BETWEEN 1 AND 256
    ),
    action_key TEXT NOT NULL CHECK (
        typeof(action_key) = 'text'
        AND action_key = trim(action_key)
        AND length(action_key) BETWEEN 1 AND 256
    ),
    attempt INTEGER NOT NULL CHECK (typeof(attempt) = 'integer' AND attempt > 0),
    idempotency_key TEXT NOT NULL CHECK (
        typeof(idempotency_key) = 'text'
        AND idempotency_key = trim(idempotency_key)
        AND length(idempotency_key) BETWEEN 1 AND 256
    ),
    offer_request_sha256 TEXT NOT NULL CHECK (
        typeof(offer_request_sha256) = 'text'
        AND length(offer_request_sha256) = 64
        AND offer_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    offer_json TEXT NOT NULL CHECK (COALESCE((
        typeof(offer_json) = 'text'
        AND length(offer_json) BETWEEN 1 AND 16777216
        AND json_valid(offer_json)
        AND json_type(offer_json) = 'object'
        AND json_extract(offer_json, '$.binding.assignment_id') = assignment_id
        AND json_extract(offer_json, '$.binding.execution_id') = execution_id
        AND json_extract(offer_json, '$.binding.action_key') = action_key
        AND json_extract(offer_json, '$.binding.attempt') = attempt
        AND json_extract(offer_json, '$.binding.idempotency_key') = idempotency_key
        AND json_extract(offer_json, '$.binding.fencing_epoch') = fencing_epoch
        AND json_extract(offer_json, '$.request_sha256') = offer_request_sha256
        AND json_extract(offer_json, '$.source.kind') = source_kind
        AND json_extract(offer_json, '$.source.repository') = repository
        AND json_extract(offer_json, '$.source.revision') = result_revision
        AND json_extract(offer_json, '$.source.advertised_ref') = advertised_ref
        AND json_extract(offer_json, '$.source.bundle.relative_path') = relative_path
        AND json_extract(offer_json, '$.source.bundle.sha256') = sha256
        AND json_extract(offer_json, '$.source.bundle.size_bytes') = size_bytes
        AND json_extract(offer_json, '$.source.bundle.media_type') = media_type
        AND (
            (
                source_kind = 'prior_phase_bundle'
                AND json_extract(offer_json, '$.source.base_revision') = base_revision
            )
            OR (
                source_kind = 'repository_snapshot_bundle'
                AND json_type(offer_json, '$.source.base_revision') IS NULL
                AND base_revision = result_revision
            )
        )
    ), 0)),
    upload_request_sha256 TEXT NOT NULL CHECK (
        typeof(upload_request_sha256) = 'text'
        AND length(upload_request_sha256) = 64
        AND upload_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    source_kind TEXT NOT NULL CHECK (
        typeof(source_kind) = 'text'
        AND source_kind IN ('prior_phase_bundle', 'repository_snapshot_bundle')
    ),
    repository TEXT NOT NULL CHECK (
        typeof(repository) = 'text'
        AND repository = trim(repository)
        AND length(repository) BETWEEN 3 AND 2048
        AND repository NOT GLOB '*[^A-Za-z0-9._/-]*'
    ),
    base_revision TEXT NOT NULL CHECK (
        typeof(base_revision) = 'text'
        AND length(base_revision) IN (40, 64)
        AND base_revision NOT GLOB '*[^0-9a-f]*'
    ),
    result_revision TEXT NOT NULL CHECK (
        typeof(result_revision) = 'text'
        AND length(result_revision) = length(base_revision)
        AND result_revision NOT GLOB '*[^0-9a-f]*'
    ),
    advertised_ref TEXT NOT NULL CHECK (typeof(advertised_ref) = 'text'),
    relative_path TEXT NOT NULL CHECK (
        typeof(relative_path) = 'text'
        AND length(relative_path) BETWEEN 1 AND 512
        AND substr(relative_path, 1, 1) != '/'
        AND relative_path NOT GLOB '*[^A-Za-z0-9._/-]*'
    ),
    sha256 TEXT NOT NULL CHECK (
        typeof(sha256) = 'text'
        AND length(sha256) = 64
        AND sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    size_bytes INTEGER NOT NULL CHECK (
        typeof(size_bytes) = 'integer' AND size_bytes BETWEEN 1 AND 33554432
    ),
    media_type TEXT NOT NULL CHECK (
        typeof(media_type) = 'text' AND media_type = 'application/x-git-bundle'
    ),
    content BLOB NOT NULL CHECK (typeof(content) = 'blob'),
    stored_at TEXT NOT NULL CHECK (
        typeof(stored_at) = 'text' AND length(trim(stored_at)) > 0
    ),
    content_pruned_at TEXT,
    CHECK (
        (
            source_kind = 'prior_phase_bundle'
            AND result_revision != base_revision
            AND advertised_ref = 'refs/harness/task-board/results/' || result_revision
        )
        OR (
            source_kind = 'repository_snapshot_bundle'
            AND result_revision = base_revision
            AND advertised_ref = 'refs/harness/task-board/sources/' || result_revision
        )
    ),
    CHECK (
        (content_pruned_at IS NULL AND length(content) = size_bytes)
        OR (
            content_pruned_at IS NOT NULL
            AND typeof(content_pruned_at) = 'text'
            AND length(trim(content_pruned_at)) > 0
            AND length(content) = 0
        )
    ),
    PRIMARY KEY (assignment_id, fencing_epoch),
    FOREIGN KEY (assignment_id, fencing_epoch)
        REFERENCES task_board_remote_assignments(assignment_id, fencing_epoch)
        ON DELETE CASCADE
) WITHOUT ROWID;

-- An authoritative receipt-absence check is followed by this immutable
-- executor tombstone before the controller may reassign the same Starting
-- attempt to a new host process generation. The tombstone prevents a delayed
-- upload or offer from reviving the abandoned predecessor generation.
CREATE TABLE task_board_remote_source_bundle_abandonments (
    assignment_id TEXT NOT NULL,
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    execution_id TEXT NOT NULL,
    action_key TEXT NOT NULL,
    attempt INTEGER NOT NULL CHECK (typeof(attempt) = 'integer' AND attempt > 0),
    idempotency_key TEXT NOT NULL,
    host_id TEXT NOT NULL,
    target_host_instance_id TEXT NOT NULL,
    offer_request_sha256 TEXT NOT NULL CHECK (
        typeof(offer_request_sha256) = 'text'
        AND length(offer_request_sha256) = 64
        AND offer_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    upload_request_sha256 TEXT NOT NULL CHECK (
        typeof(upload_request_sha256) = 'text'
        AND length(upload_request_sha256) = 64
        AND upload_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    authenticated_principal TEXT NOT NULL CHECK (
        typeof(authenticated_principal) = 'text'
        AND authenticated_principal = trim(authenticated_principal)
        AND length(authenticated_principal) BETWEEN 1 AND 256
        AND authenticated_principal = host_id
    ),
    verified_absence_sha256 TEXT NOT NULL CHECK (
        typeof(verified_absence_sha256) = 'text'
        AND length(verified_absence_sha256) = 64
        AND verified_absence_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    abandon_request_sha256 TEXT NOT NULL CHECK (
        typeof(abandon_request_sha256) = 'text'
        AND length(abandon_request_sha256) = 64
        AND abandon_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    verified_absence_checked_at TEXT NOT NULL CHECK (
        typeof(verified_absence_checked_at) = 'text'
        AND length(trim(verified_absence_checked_at)) > 0
    ),
    verified_absence_json TEXT NOT NULL CHECK (COALESCE((
        typeof(verified_absence_json) = 'text'
        AND length(verified_absence_json) BETWEEN 1 AND 32768
        AND json_valid(verified_absence_json)
        AND json_type(verified_absence_json) = 'object'
        AND json_extract(verified_absence_json, '$.binding.assignment_id') = assignment_id
        AND json_extract(verified_absence_json, '$.binding.execution_id') = execution_id
        AND json_extract(verified_absence_json, '$.binding.action_key') = action_key
        AND json_extract(verified_absence_json, '$.binding.attempt') = attempt
        AND json_extract(verified_absence_json, '$.binding.idempotency_key') = idempotency_key
        AND json_extract(verified_absence_json, '$.binding.host_id') = host_id
        AND json_extract(verified_absence_json, '$.binding.host_instance_id') = target_host_instance_id
        AND json_extract(verified_absence_json, '$.binding.fencing_epoch') = fencing_epoch
        AND json_extract(verified_absence_json, '$.offer_request_sha256') = offer_request_sha256
        AND json_extract(verified_absence_json, '$.upload_request_sha256') = upload_request_sha256
        AND json_extract(verified_absence_json, '$.checked_at') = verified_absence_checked_at
        AND json_type(verified_absence_json, '$.receipt') IS NULL
        AND json_extract(verified_absence_json, '$.response_sha256') = verified_absence_sha256
    ), 0)),
    request_json TEXT NOT NULL CHECK (COALESCE((
        typeof(request_json) = 'text'
        AND length(request_json) BETWEEN 1 AND 16810246
        AND json_valid(request_json)
        AND json_type(request_json) = 'object'
        AND json_extract(request_json, '$.offer.binding.assignment_id') = assignment_id
        AND json_extract(request_json, '$.offer.binding.execution_id') = execution_id
        AND json_extract(request_json, '$.offer.binding.action_key') = action_key
        AND json_extract(request_json, '$.offer.binding.attempt') = attempt
        AND json_extract(request_json, '$.offer.binding.idempotency_key') = idempotency_key
        AND json_extract(request_json, '$.offer.binding.host_id') = host_id
        AND json_extract(request_json, '$.offer.binding.host_instance_id') = target_host_instance_id
        AND json_extract(request_json, '$.offer.binding.fencing_epoch') = fencing_epoch
        AND json_extract(request_json, '$.offer.request_sha256') = offer_request_sha256
        AND json_extract(request_json, '$.upload_request_sha256') = upload_request_sha256
        AND json_extract(request_json, '$.verified_absence.response_sha256') = verified_absence_sha256
        AND json_extract(request_json, '$.verified_absence.checked_at') = verified_absence_checked_at
        AND json_extract(request_json, '$.reason') = 'executor_instance_replaced'
        AND json_extract(request_json, '$.request_sha256') = abandon_request_sha256
        AND json_extract(request_json, '$.verified_absence') = json(verified_absence_json)
    ), 0)),
    abandoned_by_host_instance_id TEXT NOT NULL CHECK (
        typeof(abandoned_by_host_instance_id) = 'text'
        AND abandoned_by_host_instance_id = trim(abandoned_by_host_instance_id)
        AND length(abandoned_by_host_instance_id) BETWEEN 1 AND 256
    ),
    response_json TEXT NOT NULL CHECK (COALESCE((
        typeof(response_json) = 'text'
        AND length(response_json) BETWEEN 1 AND 16384
        AND json_valid(response_json)
        AND json_type(response_json) = 'object'
        AND json_extract(response_json, '$.binding.assignment_id') = assignment_id
        AND json_extract(response_json, '$.binding.execution_id') = execution_id
        AND json_extract(response_json, '$.binding.action_key') = action_key
        AND json_extract(response_json, '$.binding.attempt') = attempt
        AND json_extract(response_json, '$.binding.idempotency_key') = idempotency_key
        AND json_extract(response_json, '$.binding.host_id') = host_id
        AND json_extract(response_json, '$.binding.host_instance_id') = target_host_instance_id
        AND json_extract(response_json, '$.binding.fencing_epoch') = fencing_epoch
        AND json_extract(response_json, '$.upload_request_sha256') = upload_request_sha256
        AND json_extract(response_json, '$.abandon_request_sha256') = abandon_request_sha256
        AND json_extract(response_json, '$.abandoned_by_host_instance_id') = abandoned_by_host_instance_id
        AND json_extract(response_json, '$.abandoned_at') = abandoned_at
        AND json_extract(response_json, '$.binding') = json_extract(request_json, '$.offer.binding')
    ), 0)),
    abandoned_at TEXT NOT NULL CHECK (
        typeof(abandoned_at) = 'text' AND length(trim(abandoned_at)) > 0
    ),
    PRIMARY KEY (assignment_id, fencing_epoch),
    UNIQUE (offer_request_sha256),
    UNIQUE (upload_request_sha256)
) WITHOUT ROWID;

-- Artifact content is a digest-bound immutable cache. It is not part of the
-- mutable assignment row and may be pruned only after the terminal deadline or
-- durable settlement retention window. The assignment itself remains as the
-- generation fence after evidence pruning.
CREATE TABLE task_board_remote_artifacts (
    assignment_id TEXT NOT NULL,
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    lease_id TEXT NOT NULL CHECK (
        typeof(lease_id) = 'text'
        AND lease_id = trim(lease_id)
        AND length(lease_id) > 0
    ),
    offer_request_sha256 TEXT NOT NULL CHECK (
        typeof(offer_request_sha256) = 'text'
        AND length(offer_request_sha256) = 64
        AND offer_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    authenticated_principal TEXT NOT NULL CHECK (
        typeof(authenticated_principal) = 'text'
        AND authenticated_principal = trim(authenticated_principal)
        AND length(authenticated_principal) > 0
    ),
    relative_path TEXT NOT NULL CHECK (
        typeof(relative_path) = 'text'
        AND length(relative_path) BETWEEN 1 AND 512
        AND substr(relative_path, 1, 1) != '/'
        AND instr(relative_path, char(0)) = 0
        AND instr(relative_path, char(92)) = 0
        AND relative_path NOT GLOB '*[^A-Za-z0-9._/-]*'
    ),
    sha256 TEXT NOT NULL CHECK (
        typeof(sha256) = 'text'
        AND length(sha256) = 64
        AND sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    size_bytes INTEGER NOT NULL CHECK (
        typeof(size_bytes) = 'integer'
        AND size_bytes BETWEEN 0 AND 33554432
    ),
    media_type TEXT NOT NULL CHECK (
        typeof(media_type) = 'text' AND length(trim(media_type)) > 0
    ),
    content BLOB NOT NULL CHECK (
        typeof(content) = 'blob' AND length(content) = size_bytes
    ),
    stored_at TEXT NOT NULL CHECK (
        typeof(stored_at) = 'text' AND length(trim(stored_at)) > 0
    ),
    PRIMARY KEY (assignment_id, fencing_epoch, relative_path),
    FOREIGN KEY (assignment_id, fencing_epoch)
        REFERENCES task_board_remote_assignments(assignment_id, fencing_epoch)
        ON DELETE CASCADE
) WITHOUT ROWID;

-- Controller-local journal for the only PR7 operation that spans SQLite and a
-- mutable Git worktree. Immutable coordinates are inserted before object or
-- ref mutation. Monotonic state then makes every crash boundary replayable
-- without resetting or cleaning user-owned worktree bytes.
CREATE TABLE task_board_remote_result_imports (
    assignment_id TEXT NOT NULL,
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    execution_id TEXT NOT NULL CHECK (
        typeof(execution_id) = 'text'
        AND execution_id = trim(execution_id)
        AND length(execution_id) > 0
    ),
    action_key TEXT NOT NULL CHECK (
        typeof(action_key) = 'text'
        AND action_key = trim(action_key)
        AND length(action_key) > 0
    ),
    attempt INTEGER NOT NULL CHECK (typeof(attempt) = 'integer' AND attempt > 0),
    idempotency_key TEXT NOT NULL CHECK (
        typeof(idempotency_key) = 'text'
        AND idempotency_key = trim(idempotency_key)
        AND length(idempotency_key) > 0
    ),
    offer_request_sha256 TEXT NOT NULL CHECK (
        typeof(offer_request_sha256) = 'text'
        AND length(offer_request_sha256) = 64
        AND offer_request_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    status_sha256 TEXT NOT NULL CHECK (
        typeof(status_sha256) = 'text'
        AND length(status_sha256) = 64
        AND status_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    result_sha256 TEXT NOT NULL CHECK (
        typeof(result_sha256) = 'text'
        AND length(result_sha256) = 64
        AND result_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    result_artifact_sha256 TEXT NOT NULL CHECK (
        typeof(result_artifact_sha256) = 'text'
        AND length(result_artifact_sha256) = 64
        AND result_artifact_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    bundle_sha256 TEXT NOT NULL CHECK (
        typeof(bundle_sha256) = 'text'
        AND length(bundle_sha256) = 64
        AND bundle_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    parent_record_sha256 TEXT NOT NULL CHECK (
        typeof(parent_record_sha256) = 'text'
        AND length(parent_record_sha256) = 64
        AND parent_record_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    worktree_path TEXT NOT NULL CHECK (
        typeof(worktree_path) = 'text'
        AND worktree_path = trim(worktree_path)
        AND length(worktree_path) BETWEEN 1 AND 4096
    ),
    git_dir TEXT NOT NULL CHECK (
        typeof(git_dir) = 'text'
        AND git_dir = trim(git_dir)
        AND length(git_dir) BETWEEN 1 AND 4096
    ),
    common_git_dir TEXT NOT NULL CHECK (
        typeof(common_git_dir) = 'text'
        AND common_git_dir = trim(common_git_dir)
        AND length(common_git_dir) BETWEEN 1 AND 4096
    ),
    branch_ref TEXT NOT NULL CHECK (
        typeof(branch_ref) = 'text'
        AND branch_ref GLOB 'refs/heads/?*'
        AND length(branch_ref) BETWEEN 12 AND 1024
    ),
    base_revision TEXT NOT NULL CHECK (typeof(base_revision) = 'text'),
    result_revision TEXT NOT NULL CHECK (typeof(result_revision) = 'text'),
    advertised_ref TEXT NOT NULL CHECK (
        typeof(advertised_ref) = 'text'
        AND advertised_ref GLOB 'refs/harness/task-board/results/?*'
        AND length(advertised_ref) BETWEEN 34 AND 1024
    ),
    import_ref TEXT NOT NULL CHECK (
        typeof(import_ref) = 'text'
        AND import_ref GLOB 'refs/harness/task-board/imports/?*'
        AND length(import_ref) BETWEEN 34 AND 1024
    ),
    object_format TEXT NOT NULL CHECK (
        typeof(object_format) = 'text' AND object_format IN ('sha1', 'sha256')
    ),
    import_sha256 TEXT NOT NULL UNIQUE CHECK (
        typeof(import_sha256) = 'text'
        AND length(import_sha256) = 64
        AND import_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    state TEXT NOT NULL CHECK (
        typeof(state) = 'text'
        AND state IN ('prepared', 'applied', 'adopted', 'manual_required')
    ),
    prepared_at TEXT NOT NULL CHECK (
        typeof(prepared_at) = 'text' AND length(trim(prepared_at)) > 0
    ),
    applied_at TEXT,
    adopted_at TEXT,
    last_error TEXT,
    CHECK (
        (
            object_format = 'sha1'
            AND length(base_revision) = 40
            AND length(result_revision) = 40
        )
        OR (
            object_format = 'sha256'
            AND length(base_revision) = 64
            AND length(result_revision) = 64
        )
    ),
    CHECK (
        base_revision NOT GLOB '*[^0-9a-f]*'
        AND result_revision NOT GLOB '*[^0-9a-f]*'
        AND base_revision != result_revision
    ),
    CHECK (
        (state = 'prepared' AND applied_at IS NULL AND adopted_at IS NULL)
        OR (
            state = 'applied'
            AND typeof(applied_at) = 'text'
            AND length(trim(applied_at)) > 0
            AND adopted_at IS NULL
        )
        OR (
            state = 'adopted'
            AND typeof(applied_at) = 'text'
            AND length(trim(applied_at)) > 0
            AND typeof(adopted_at) = 'text'
            AND length(trim(adopted_at)) > 0
        )
        OR (state = 'manual_required' AND adopted_at IS NULL)
    ),
    CHECK (
        (state = 'manual_required' AND typeof(last_error) = 'text'
            AND length(trim(last_error)) > 0)
        OR (state != 'manual_required' AND last_error IS NULL)
    ),
    PRIMARY KEY (assignment_id, fencing_epoch),
    FOREIGN KEY (assignment_id, fencing_epoch)
        REFERENCES task_board_remote_assignments(assignment_id, fencing_epoch)
        ON DELETE CASCADE
) WITHOUT ROWID;

-- A failed recovery row quarantines only the exact assignment generation and
-- mutable state snapshot that produced the failure. Any assignment mutation
-- makes the comparison columns diverge and restores immediate eligibility.
CREATE TABLE task_board_remote_recovery_quarantine (
    assignment_id TEXT PRIMARY KEY,
    fencing_epoch INTEGER NOT NULL CHECK (
        typeof(fencing_epoch) = 'integer' AND fencing_epoch > 0
    ),
    assignment_state TEXT NOT NULL CHECK (
        assignment_state IN (
            'offered', 'claimed', 'started', 'running', 'completed', 'failed',
            'cancelled', 'superseded', 'unknown'
        )
    ),
    assignment_updated_at TEXT NOT NULL CHECK (
        typeof(assignment_updated_at) = 'text'
        AND length(trim(assignment_updated_at)) > 0
    ),
    state_fingerprint TEXT NOT NULL CHECK (
        typeof(state_fingerprint) = 'text'
        AND length(state_fingerprint) = 64
        AND state_fingerprint NOT GLOB '*[^0-9a-f]*'
    ),
    failure_count INTEGER NOT NULL CHECK (
        typeof(failure_count) = 'integer' AND failure_count > 0
    ),
    next_attempt_at TEXT NOT NULL CHECK (
        typeof(next_attempt_at) = 'text' AND length(trim(next_attempt_at)) > 0
    ),
    last_error_code TEXT NOT NULL CHECK (
        typeof(last_error_code) = 'text' AND length(trim(last_error_code)) > 0
    ),
    updated_at TEXT NOT NULL CHECK (
        typeof(updated_at) = 'text' AND length(trim(updated_at)) > 0
    ),
    FOREIGN KEY (assignment_id, fencing_epoch)
        REFERENCES task_board_remote_assignments(assignment_id, fencing_epoch)
        ON DELETE CASCADE
) WITHOUT ROWID;

CREATE UNIQUE INDEX task_board_remote_assignments_exact_attempt
    ON task_board_remote_assignments(execution_id, action_key, attempt)
    WHERE legacy_migrated = 0
      AND state IN ('offered', 'claimed', 'started', 'running', 'unknown');
CREATE UNIQUE INDEX task_board_remote_assignments_active_idempotency
    ON task_board_remote_assignments(idempotency_key)
    WHERE legacy_migrated = 0
      AND state IN ('offered', 'claimed', 'started', 'running', 'unknown');
CREATE UNIQUE INDEX task_board_remote_assignments_execution_epoch
    ON task_board_remote_assignments(execution_id, fencing_epoch)
    WHERE legacy_migrated = 0;
CREATE UNIQUE INDEX task_board_remote_assignments_request_digest
    ON task_board_remote_assignments(request_sha256)
    WHERE legacy_migrated = 0;
CREATE UNIQUE INDEX task_board_remote_assignments_host_lease
    ON task_board_remote_assignments(host_id, lease_id)
    WHERE lease_id IS NOT NULL;
CREATE INDEX task_board_remote_assignments_active_host
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
CREATE INDEX task_board_remote_assignments_exact_attempt_history
    ON task_board_remote_assignments(
        execution_id, action_key, attempt, fencing_epoch DESC, assignment_id
    );
CREATE INDEX task_board_remote_assignments_recovery
    ON task_board_remote_assignments(
        state, lease_expires_at, deadline_at, updated_at, assignment_id
    )
    WHERE state IN ('offered', 'claimed', 'started', 'running', 'unknown');
CREATE INDEX task_board_execution_hosts_eligible
    ON task_board_execution_hosts(
        host_role, enabled, observed_state, observed_received_at,
        observed_heartbeat_at, host_id
    );
CREATE UNIQUE INDEX task_board_remote_offer_receipts_idempotency
    ON task_board_remote_offer_receipts(idempotency_key);
CREATE UNIQUE INDEX task_board_remote_offer_receipts_request_digest
    ON task_board_remote_offer_receipts(request_sha256);
CREATE UNIQUE INDEX task_board_remote_offer_receipts_exact_attempt
    ON task_board_remote_offer_receipts(execution_id, action_key, attempt);
CREATE UNIQUE INDEX task_board_remote_offer_receipts_execution_epoch
    ON task_board_remote_offer_receipts(execution_id, fencing_epoch);
CREATE UNIQUE INDEX task_board_remote_settlement_receipts_request_digest
    ON task_board_remote_settlement_receipts(request_sha256);
CREATE UNIQUE INDEX task_board_remote_settlement_receipts_exact_attempt
    ON task_board_remote_settlement_receipts(execution_id, action_key, attempt);
CREATE UNIQUE INDEX task_board_remote_settlement_receipts_execution_epoch
    ON task_board_remote_settlement_receipts(execution_id, fencing_epoch);
CREATE INDEX task_board_remote_settlement_receipts_retention
    ON task_board_remote_settlement_receipts(settled_at, assignment_id);
CREATE UNIQUE INDEX task_board_remote_source_bundles_offer_digest
    ON task_board_remote_source_bundles(offer_request_sha256);
CREATE UNIQUE INDEX task_board_remote_source_bundles_upload_digest
    ON task_board_remote_source_bundles(upload_request_sha256);
CREATE UNIQUE INDEX task_board_remote_outbound_sources_offer_digest
    ON task_board_remote_outbound_sources(offer_request_sha256);
CREATE UNIQUE INDEX task_board_remote_outbound_sources_upload_digest
    ON task_board_remote_outbound_sources(upload_request_sha256);
CREATE INDEX task_board_remote_outbound_sources_attempt
    ON task_board_remote_outbound_sources(
        execution_id, action_key, attempt, fencing_epoch, assignment_id
    );
CREATE INDEX task_board_remote_source_bundle_abandonments_attempt
    ON task_board_remote_source_bundle_abandonments(
        execution_id, action_key, attempt, fencing_epoch
    );
CREATE UNIQUE INDEX task_board_remote_source_bundle_abandonments_generation
    ON task_board_remote_source_bundle_abandonments(execution_id, fencing_epoch);
CREATE INDEX task_board_remote_artifacts_retention
    ON task_board_remote_artifacts(stored_at, assignment_id, fencing_epoch);
CREATE INDEX task_board_remote_result_imports_recovery
    ON task_board_remote_result_imports(state, prepared_at, assignment_id, fencing_epoch)
    WHERE state IN ('prepared', 'applied');
CREATE INDEX task_board_remote_recovery_quarantine_retry
    ON task_board_remote_recovery_quarantine(next_attempt_at, assignment_id);

-- Pre-v43 local report/publish recovery could persist a targetless Starting
-- child. Mark only the exact unique active generation that already existed at
-- upgrade time. The marker carries the full attempt identity and is consumed
-- by the one legacy Starting -> Running local-target adoption transaction;
-- ordinary v43 targetless rows never receive this authority.
UPDATE task_board_workflow_executions AS execution
SET resource_ownership_json = json_set(
        execution.resource_ownership_json,
        '$.resources.legacy_local_target_adoption',
        'v43_migrated',
        '$.resources.legacy_local_target_action_key',
        (
            SELECT attempt.action_key
            FROM task_board_execution_attempts AS attempt
            WHERE attempt.execution_id = execution.execution_id
              AND attempt.state = 'starting'
        ),
        '$.resources.legacy_local_target_attempt',
        CAST((
            SELECT attempt.attempt
            FROM task_board_execution_attempts AS attempt
            WHERE attempt.execution_id = execution.execution_id
              AND attempt.state = 'starting'
        ) AS TEXT),
        '$.resources.legacy_local_target_idempotency_key',
        (
            SELECT attempt.idempotency_key
            FROM task_board_execution_attempts AS attempt
            WHERE attempt.execution_id = execution.execution_id
              AND attempt.state = 'starting'
        )
    )
WHERE execution.phase IN ('implementation', 'review', 'evaluate', 'publish')
  AND execution.state IN ('pending', 'starting', 'running')
  AND execution.host_id IS NULL
  AND json_type(
        execution.resource_ownership_json,
        '$.resources.execution_target'
      ) IS NULL
  AND json_type(
        execution.resource_ownership_json,
        '$.resources.execution_target_action_key'
      ) IS NULL
  AND json_type(
        execution.resource_ownership_json,
        '$.resources.execution_target_attempt'
      ) IS NULL
  AND json_type(
        execution.resource_ownership_json,
        '$.resources.legacy_local_target_adoption'
      ) IS NULL
  AND json_type(
        execution.resource_ownership_json,
        '$.resources.legacy_local_target_action_key'
      ) IS NULL
  AND json_type(
        execution.resource_ownership_json,
        '$.resources.legacy_local_target_attempt'
      ) IS NULL
  AND json_type(
        execution.resource_ownership_json,
        '$.resources.legacy_local_target_idempotency_key'
      ) IS NULL
  AND (
      SELECT COUNT(*)
      FROM task_board_execution_attempts AS active
      WHERE active.execution_id = execution.execution_id
        AND active.state IN ('preparing', 'starting', 'running')
  ) = 1
  AND (
      SELECT COUNT(*)
      FROM task_board_execution_attempts AS starting
      WHERE starting.execution_id = execution.execution_id
        AND starting.state = 'starting'
  ) = 1;

UPDATE schema_meta SET value = '43' WHERE key = 'version';
