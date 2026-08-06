CREATE TABLE IF NOT EXISTS agent_workspace_teams (
    workspace_id               TEXT PRIMARY KEY
                               REFERENCES agent_workspaces(workspace_id) ON DELETE CASCADE,
    authority                  TEXT NOT NULL DEFAULT 'workspace'
                               CHECK (authority IN ('legacy_session', 'workspace')),
    selected_legacy_session_id TEXT,
    selected_lifecycle         TEXT
                               CHECK (selected_lifecycle IN ('active', 'stale', 'ended')),
    leader_member_id           TEXT,
    source_revision            INTEGER NOT NULL DEFAULT 1 CHECK (source_revision >= 0),
    reconciled_revision        INTEGER NOT NULL DEFAULT 0 CHECK (reconciled_revision >= 0),
    shadow_digest              TEXT NOT NULL,
    created_at                 TEXT NOT NULL,
    updated_at                 TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS agent_workspace_members (
    workspace_id        TEXT NOT NULL
                        REFERENCES agent_workspace_teams(workspace_id) ON DELETE CASCADE,
    member_id           TEXT NOT NULL,
    runtime_kind        TEXT NOT NULL,
    managed_agent_kind  TEXT CHECK (managed_agent_kind IN ('tui', 'acp', 'codex')),
    managed_agent_id    TEXT,
    display_name        TEXT NOT NULL,
    role                TEXT CHECK (role IN ('leader', 'observer', 'worker', 'reviewer', 'improver')),
    membership_status   TEXT NOT NULL CHECK (membership_status IN (
                            'pending_registration', 'joined', 'removed', 'historical'
                        )),
    liveness_status     TEXT NOT NULL CHECK (liveness_status IN (
                            'active', 'idle', 'awaiting_review', 'disconnected',
                            'removed', 'unknown'
                        )),
    runtime_session_id  TEXT,
    assignment_id       TEXT,
    runtime_lifecycle   TEXT NOT NULL CHECK (runtime_lifecycle IN (
                            'running', 'recoverable', 'completed', 'failed', 'unavailable'
                        )),
    runtime_evidence    TEXT NOT NULL,
    source_session_id   TEXT,
    source_agent_id     TEXT,
    source_digest       TEXT NOT NULL,
    membership_source_digest          TEXT NOT NULL,
    runtime_source_digest             TEXT NOT NULL,
    membership_override_source_digest TEXT,
    runtime_override_source_digest    TEXT,
    joined_at           TEXT,
    last_activity_at    TEXT,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    PRIMARY KEY (workspace_id, member_id),
    CHECK (
        (managed_agent_kind IS NULL AND managed_agent_id IS NULL)
        OR (managed_agent_kind IS NOT NULL AND managed_agent_id IS NOT NULL)
    )
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_workspace_member_managed_identity
    ON agent_workspace_members(workspace_id, managed_agent_kind, managed_agent_id)
    WHERE managed_agent_kind IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_agent_workspace_member_managed_lookup
    ON agent_workspace_members(managed_agent_kind, managed_agent_id, workspace_id)
    WHERE managed_agent_kind IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_agent_workspace_member_source
    ON agent_workspace_members(source_session_id, source_agent_id);

CREATE TABLE IF NOT EXISTS agent_workspace_member_provenance (
    workspace_id      TEXT NOT NULL,
    member_id         TEXT NOT NULL,
    source_session_id TEXT NOT NULL,
    source_agent_id   TEXT NOT NULL,
    source_digest     TEXT NOT NULL,
    is_selected       INTEGER NOT NULL CHECK (is_selected IN (0, 1)),
    PRIMARY KEY (workspace_id, source_session_id, source_agent_id),
    FOREIGN KEY (workspace_id, member_id)
        REFERENCES agent_workspace_members(workspace_id, member_id) ON DELETE CASCADE
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_agent_workspace_member_provenance_member
    ON agent_workspace_member_provenance(workspace_id, member_id);
CREATE INDEX IF NOT EXISTS idx_agent_workspace_member_provenance_source
    ON agent_workspace_member_provenance(
        source_session_id, source_agent_id, workspace_id
    );

CREATE INDEX IF NOT EXISTS idx_agent_workspace_legacy_sessions_session
    ON agent_workspace_legacy_sessions(session_id, workspace_id);

CREATE TABLE IF NOT EXISTS agent_workspace_member_operations (
    operation_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id      TEXT NOT NULL UNIQUE,
    workspace_id      TEXT NOT NULL,
    member_id         TEXT NOT NULL,
    operation_kind    TEXT NOT NULL CHECK (operation_kind IN (
                          'runtime_stop', 'membership_remove'
                      )),
    outcome           TEXT NOT NULL CHECK (outcome IN ('succeeded', 'failed')),
    before_state      TEXT NOT NULL,
    after_state       TEXT NOT NULL,
    source_marker     TEXT NOT NULL,
    detail            TEXT,
    recorded_at       TEXT NOT NULL,
    FOREIGN KEY (workspace_id, member_id)
        REFERENCES agent_workspace_members(workspace_id, member_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agent_workspace_member_operations_member
    ON agent_workspace_member_operations(
        workspace_id, member_id, operation_sequence DESC
    );

INSERT INTO agent_workspace_teams (
    workspace_id, authority, selected_legacy_session_id, selected_lifecycle,
    leader_member_id, source_revision, reconciled_revision, shadow_digest,
    created_at, updated_at
)
SELECT workspace.workspace_id, 'workspace', workspace.selected_legacy_session_id,
       provenance.lifecycle, NULL, 1, 0, '',
       workspace.created_at, workspace.updated_at
FROM agent_workspaces workspace
LEFT JOIN agent_workspace_legacy_sessions provenance
  ON provenance.workspace_id = workspace.workspace_id
 AND provenance.session_id = workspace.selected_legacy_session_id
ON CONFLICT(workspace_id) DO NOTHING;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_agent_insert
AFTER INSERT ON agents
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_legacy_sessions
        WHERE session_id = NEW.session_id
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_agent_update
AFTER UPDATE ON agents
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_legacy_sessions
        WHERE session_id IN (OLD.session_id, NEW.session_id)
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_agent_delete
AFTER DELETE ON agents
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_legacy_sessions
        WHERE session_id = OLD.session_id
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_session_update
AFTER UPDATE OF leader_id, status, state_json ON sessions
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_legacy_sessions
        WHERE session_id = NEW.session_id
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_tui_insert
AFTER INSERT ON agent_tuis
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_legacy_sessions
        WHERE session_id = NEW.session_id
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_tui_update
AFTER UPDATE ON agent_tuis
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
           SELECT workspace_id FROM agent_workspace_legacy_sessions
           WHERE session_id IN (OLD.session_id, NEW.session_id)
       )
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_members
           WHERE managed_agent_kind = 'tui' AND managed_agent_id = NEW.tui_id
       );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_tui_delete
AFTER DELETE ON agent_tuis
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
           SELECT workspace_id FROM agent_workspace_legacy_sessions
           WHERE session_id = OLD.session_id
       )
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_members
           WHERE managed_agent_kind = 'tui' AND managed_agent_id = OLD.tui_id
       );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_codex_insert
AFTER INSERT ON codex_runs
WHEN NEW.session_id IS NOT NULL
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_legacy_sessions
        WHERE session_id = NEW.session_id
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_codex_update
AFTER UPDATE ON codex_runs
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
           SELECT workspace_id FROM agent_workspace_legacy_sessions
           WHERE session_id IN (OLD.session_id, NEW.session_id)
       )
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_members
           WHERE managed_agent_kind = 'codex' AND managed_agent_id = NEW.run_id
       );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_codex_delete
AFTER DELETE ON codex_runs
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
           SELECT workspace_id FROM agent_workspace_legacy_sessions
           WHERE session_id = OLD.session_id
       )
       OR workspace_id IN (
           SELECT workspace_id FROM agent_workspace_members
           WHERE managed_agent_kind = 'codex' AND managed_agent_id = OLD.run_id
       );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_provenance_insert
AFTER INSERT ON agent_workspace_legacy_sessions
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = NEW.workspace_id;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_provenance_update
AFTER UPDATE ON agent_workspace_legacy_sessions
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (OLD.workspace_id, NEW.workspace_id);
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_source_provenance_delete
AFTER DELETE ON agent_workspace_legacy_sessions
BEGIN
    UPDATE agent_workspace_teams
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = OLD.workspace_id;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_team_detach_session
BEFORE DELETE ON sessions
BEGIN
    SELECT RAISE(
        ABORT,
        'cannot detach Session before agent workspace reconciliation'
    )
    WHERE (
        EXISTS (SELECT 1 FROM agents WHERE session_id = OLD.session_id)
        OR EXISTS (SELECT 1 FROM agent_tuis WHERE session_id = OLD.session_id)
        OR EXISTS (SELECT 1 FROM codex_runs WHERE session_id = OLD.session_id)
    ) AND NOT EXISTS (
        SELECT 1
        FROM agent_workspace_legacy_sessions link
        JOIN agent_workspace_teams team ON team.workspace_id = link.workspace_id
        WHERE link.session_id = OLD.session_id
    );

    SELECT RAISE(
        ABORT,
        'cannot detach Session with conflicting managed agent bindings'
    )
    WHERE EXISTS (
        SELECT 1
        FROM agent_workspace_legacy_sessions target_link
        JOIN agent_workspace_legacy_sessions left_link
          ON left_link.workspace_id = target_link.workspace_id
        JOIN agent_workspace_legacy_sessions right_link
          ON right_link.workspace_id = target_link.workspace_id
        JOIN agents left_agent ON left_agent.session_id = left_link.session_id
        JOIN agents right_agent ON right_agent.session_id = right_link.session_id
        WHERE target_link.session_id = OLD.session_id
          AND (left_agent.session_id = OLD.session_id
               OR right_agent.session_id = OLD.session_id)
          AND left_agent.managed_agent_kind IN ('tui', 'acp', 'codex')
          AND left_agent.managed_agent_kind = right_agent.managed_agent_kind
          AND left_agent.managed_agent_id IS NOT NULL
          AND left_agent.managed_agent_id <> ''
          AND left_agent.managed_agent_id = right_agent.managed_agent_id
          AND left_agent.agent_session_id IS NOT NULL
          AND right_agent.agent_session_id IS NOT NULL
          AND left_agent.agent_session_id <> right_agent.agent_session_id
    );

    SELECT RAISE(
        ABORT,
        'cannot detach Session with conflicting Codex runtime binding'
    )
    WHERE EXISTS (
        SELECT 1
        FROM agent_workspace_legacy_sessions target_link
        JOIN agent_workspace_legacy_sessions agent_link
          ON agent_link.workspace_id = target_link.workspace_id
        JOIN agents agent ON agent.session_id = agent_link.session_id
        JOIN agent_workspace_legacy_sessions run_link
          ON run_link.workspace_id = target_link.workspace_id
        JOIN codex_runs run ON run.session_id = run_link.session_id
                            AND run.run_id = agent.managed_agent_id
        WHERE target_link.session_id = OLD.session_id
          AND (agent.session_id = OLD.session_id OR run.session_id = OLD.session_id)
          AND agent.managed_agent_kind = 'codex'
          AND agent.managed_agent_id IS NOT NULL
          AND agent.managed_agent_id <> ''
          AND agent.agent_session_id IS NOT NULL
          AND agent.agent_session_id <> ''
          AND run.thread_id IS NOT NULL
          AND run.thread_id <> ''
          AND agent.agent_session_id <> run.thread_id
    );

    SELECT RAISE(
        ABORT,
        'cannot detach Session before agent team reconciliation'
    )
    WHERE EXISTS (
        SELECT 1
        FROM agent_workspace_legacy_sessions link
        JOIN agent_workspace_teams team ON team.workspace_id = link.workspace_id
        WHERE link.session_id = OLD.session_id
          AND team.source_revision <> team.reconciled_revision
    );

    INSERT INTO agent_workspace_members (
        workspace_id, member_id, runtime_kind, managed_agent_kind,
        managed_agent_id, display_name, role, membership_status,
        liveness_status, runtime_session_id, assignment_id, runtime_lifecycle,
        runtime_evidence, source_session_id, source_agent_id, source_digest,
        membership_source_digest, runtime_source_digest,
        membership_override_source_digest, runtime_override_source_digest,
        joined_at, last_activity_at, created_at, updated_at
    )
    SELECT team.workspace_id,
           CASE
               WHEN agent.managed_agent_kind IN ('tui', 'acp', 'codex')
                    AND agent.managed_agent_id IS NOT NULL
                    AND agent.managed_agent_id <> ''
                   THEN 'member-m-' || lower(hex(agent.managed_agent_kind)) || '-' || lower(hex(agent.managed_agent_id))
               ELSE 'member-l-' || lower(hex(agent.session_id)) || '-' || lower(hex(agent.agent_id))
           END,
           agent.runtime,
           CASE WHEN agent.managed_agent_kind IN ('tui', 'acp', 'codex')
                      AND agent.managed_agent_id IS NOT NULL
                      AND agent.managed_agent_id <> ''
                THEN agent.managed_agent_kind END,
           CASE WHEN agent.managed_agent_kind IN ('tui', 'acp', 'codex')
                      AND agent.managed_agent_id IS NOT NULL
                      AND agent.managed_agent_id <> ''
                THEN agent.managed_agent_id END,
           agent.name,
           CASE WHEN agent.role IN ('leader', 'observer', 'worker', 'reviewer', 'improver')
                THEN agent.role END,
           CASE
               WHEN team.selected_legacy_session_id IS NOT OLD.session_id THEN 'historical'
               WHEN agent.status = '"removed"' THEN 'removed'
               ELSE 'joined'
           END,
           CASE
               WHEN team.selected_legacy_session_id IS NOT OLD.session_id THEN 'unknown'
               WHEN agent.status = '"active"' THEN 'active'
               WHEN agent.status = '"idle"' THEN 'idle'
               WHEN agent.status = '"awaiting_review"' THEN 'awaiting_review'
               WHEN agent.status = '"removed"' THEN 'removed'
               WHEN json_valid(agent.status) AND json_extract(agent.status, '$.state') = 'disconnected'
                   THEN 'disconnected'
               ELSE 'unknown'
           END,
           agent.agent_session_id, agent.current_task_id,
           CASE
               WHEN agent.managed_agent_kind = 'acp'
                    AND json_valid(agent.status)
                    AND json_extract(agent.status, '$.state') = 'disconnected'
                    AND json_extract(agent.status, '$.reason.kind') IN (
                        'process_exited', 'stdio_closed', 'transport_closed',
                        'initialize_timeout', 'prompt_timeout', 'watchdog_fired',
                        'oom_killed'
                    ) THEN 'recoverable'
               WHEN agent.managed_agent_kind = 'acp'
                    AND json_valid(agent.status)
                    AND json_extract(agent.status, '$.state') = 'disconnected'
                    AND json_extract(agent.status, '$.reason.kind') IN (
                        'user_cancelled', 'session_stopped', 'session_ended'
                    ) THEN 'completed'
               ELSE 'unavailable'
           END,
           'family=' || agent.runtime || ';status=' || agent.status,
           agent.session_id, agent.agent_id,
           lower(hex(agent.session_id || char(0) || agent.agent_id || char(0) || agent.updated_at)),
           lower(hex(agent.status || char(0) || agent.updated_at)),
           lower(hex(agent.status || char(0) || agent.updated_at)),
           NULL, NULL,
           agent.joined_at, agent.last_activity_at, agent.joined_at, agent.updated_at
    FROM agent_workspace_teams team
    JOIN agent_workspace_legacy_sessions link
      ON link.workspace_id = team.workspace_id AND link.session_id = OLD.session_id
    JOIN agents agent ON agent.session_id = OLD.session_id
    ON CONFLICT(workspace_id, member_id) DO UPDATE SET
        runtime_kind = excluded.runtime_kind,
        managed_agent_kind = excluded.managed_agent_kind,
        managed_agent_id = excluded.managed_agent_id,
        display_name = excluded.display_name,
        role = excluded.role,
        membership_status = CASE
            WHEN agent_workspace_members.membership_override_source_digest IS NOT NULL
            THEN 'removed' ELSE excluded.membership_status END,
        liveness_status = CASE
            WHEN agent_workspace_members.membership_override_source_digest IS NOT NULL
            THEN 'removed' ELSE excluded.liveness_status END,
        runtime_session_id = excluded.runtime_session_id,
        assignment_id = excluded.assignment_id,
        runtime_lifecycle = CASE
            WHEN excluded.membership_status = 'removed'
            THEN agent_workspace_members.runtime_lifecycle
            WHEN excluded.managed_agent_kind IN ('tui', 'codex')
            THEN agent_workspace_members.runtime_lifecycle
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN 'completed' ELSE excluded.runtime_lifecycle END,
        runtime_evidence = CASE
            WHEN excluded.membership_status = 'removed'
            THEN agent_workspace_members.runtime_evidence
            WHEN excluded.managed_agent_kind IN ('tui', 'codex')
            THEN agent_workspace_members.runtime_evidence
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN 'runtime_stop_succeeded' ELSE excluded.runtime_evidence END,
        source_session_id = excluded.source_session_id,
        source_agent_id = excluded.source_agent_id,
        source_digest = excluded.source_digest,
        membership_source_digest = excluded.membership_source_digest,
        runtime_source_digest = CASE
            WHEN excluded.membership_status = 'removed'
            THEN agent_workspace_members.runtime_source_digest
            WHEN excluded.managed_agent_kind IN ('tui', 'codex')
            THEN agent_workspace_members.runtime_source_digest
            ELSE excluded.runtime_source_digest END,
        membership_override_source_digest =
            agent_workspace_members.membership_override_source_digest,
        runtime_override_source_digest = CASE
            WHEN excluded.membership_status = 'removed'
            THEN agent_workspace_members.runtime_override_source_digest
            WHEN excluded.managed_agent_kind IN ('tui', 'codex')
            THEN agent_workspace_members.runtime_override_source_digest
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN agent_workspace_members.runtime_override_source_digest END,
        joined_at = excluded.joined_at,
        last_activity_at = excluded.last_activity_at,
        updated_at = excluded.updated_at
    WHERE excluded.membership_status <> 'historical'
       OR agent_workspace_members.source_session_id = OLD.session_id;

    INSERT INTO agent_workspace_member_provenance (
        workspace_id, member_id, source_session_id, source_agent_id,
        source_digest, is_selected
    )
    SELECT team.workspace_id,
           CASE
               WHEN agent.managed_agent_kind IN ('tui', 'acp', 'codex')
                    AND agent.managed_agent_id IS NOT NULL
                    AND agent.managed_agent_id <> ''
                   THEN 'member-m-' || lower(hex(agent.managed_agent_kind)) || '-' || lower(hex(agent.managed_agent_id))
               ELSE 'member-l-' || lower(hex(agent.session_id)) || '-' || lower(hex(agent.agent_id))
           END,
           agent.session_id, agent.agent_id,
           lower(hex(agent.session_id || char(0) || agent.agent_id || char(0) || agent.updated_at)),
           team.selected_legacy_session_id = OLD.session_id
    FROM agent_workspace_teams team
    JOIN agent_workspace_legacy_sessions link
      ON link.workspace_id = team.workspace_id AND link.session_id = OLD.session_id
    JOIN agents agent ON agent.session_id = OLD.session_id
    ON CONFLICT(workspace_id, source_session_id, source_agent_id) DO UPDATE SET
        member_id = excluded.member_id,
        source_digest = excluded.source_digest,
        is_selected = excluded.is_selected;

    INSERT INTO agent_workspace_members (
        workspace_id, member_id, runtime_kind, managed_agent_kind,
        managed_agent_id, display_name, role, membership_status,
        liveness_status, runtime_session_id, assignment_id, runtime_lifecycle,
        runtime_evidence, source_session_id, source_agent_id, source_digest,
        membership_source_digest, runtime_source_digest,
        membership_override_source_digest, runtime_override_source_digest,
        joined_at, last_activity_at, created_at, updated_at
    )
    SELECT team.workspace_id,
           'member-m-' || lower(hex('tui')) || '-' || lower(hex(tui.tui_id)),
           tui.runtime, 'tui', tui.tui_id, tui.tui_id, NULL,
           CASE WHEN team.selected_legacy_session_id = OLD.session_id
                THEN 'pending_registration' ELSE 'historical' END,
           'unknown', NULL, NULL,
           CASE
               WHEN tui.status IN ('starting', 'running') THEN 'recoverable'
               WHEN tui.status IN ('exited', 'stopped') THEN 'completed'
               ELSE 'failed'
           END,
           'family=tui;status=' || tui.status
               || ';primary=' || COALESCE(CAST(tui.exit_code AS TEXT), '')
               || ';secondary=' || COALESCE(tui.signal, '')
               || ';error=' || COALESCE(tui.error, ''),
           tui.session_id, NULLIF(tui.agent_id, ''),
           lower(hex(tui.tui_id || char(0) || tui.status || char(0) || tui.updated_at)),
           '', lower(hex(tui.tui_id || char(0) || tui.status || char(0) || tui.updated_at)),
           NULL, NULL,
           NULL, tui.updated_at, tui.created_at, tui.updated_at
    FROM agent_workspace_teams team
    JOIN agent_workspace_legacy_sessions link
      ON link.workspace_id = team.workspace_id AND link.session_id = OLD.session_id
    JOIN agent_tuis tui ON tui.session_id = OLD.session_id
    ON CONFLICT(workspace_id, member_id) DO UPDATE SET
        runtime_kind = excluded.runtime_kind,
        runtime_lifecycle = CASE
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN 'completed' ELSE excluded.runtime_lifecycle END,
        runtime_evidence = CASE
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN 'runtime_stop_succeeded' ELSE excluded.runtime_evidence END,
        runtime_source_digest = excluded.runtime_source_digest,
        runtime_override_source_digest = CASE
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN agent_workspace_members.runtime_override_source_digest END,
        last_activity_at = excluded.last_activity_at,
        updated_at = excluded.updated_at
    WHERE excluded.membership_status <> 'historical'
       OR agent_workspace_members.source_session_id = OLD.session_id;

    INSERT INTO agent_workspace_members (
        workspace_id, member_id, runtime_kind, managed_agent_kind,
        managed_agent_id, display_name, role, membership_status,
        liveness_status, runtime_session_id, assignment_id, runtime_lifecycle,
        runtime_evidence, source_session_id, source_agent_id, source_digest,
        membership_source_digest, runtime_source_digest,
        membership_override_source_digest, runtime_override_source_digest,
        joined_at, last_activity_at, created_at, updated_at
    )
    SELECT team.workspace_id,
           'member-m-' || lower(hex('codex')) || '-' || lower(hex(run.run_id)),
           'codex', 'codex', run.run_id, COALESCE(run.display_name, run.run_id), NULL,
           CASE WHEN team.selected_legacy_session_id = OLD.session_id
                THEN 'pending_registration' ELSE 'historical' END,
           'unknown', run.thread_id, run.task_id,
           CASE
               WHEN run.status IN ('queued', 'running', 'waiting_approval') THEN 'recoverable'
               WHEN run.status IN ('completed', 'cancelled') THEN 'completed'
               ELSE 'failed'
           END,
           'family=codex;status=' || run.status
               || ';primary=' || COALESCE(run.thread_id, '')
               || ';secondary=;error=' || COALESCE(run.error, ''),
           run.session_id, run.session_agent_id,
           lower(hex(run.run_id || char(0) || run.status || char(0) || run.updated_at)),
           '', lower(hex(run.run_id || char(0) || run.status || char(0) || run.updated_at)),
           NULL, NULL,
           NULL, run.updated_at, run.created_at, run.updated_at
    FROM agent_workspace_teams team
    JOIN agent_workspace_legacy_sessions link
      ON link.workspace_id = team.workspace_id AND link.session_id = OLD.session_id
    JOIN codex_runs run ON run.session_id = OLD.session_id
    ON CONFLICT(workspace_id, member_id) DO UPDATE SET
        runtime_session_id = COALESCE(excluded.runtime_session_id, runtime_session_id),
        assignment_id = COALESCE(excluded.assignment_id, assignment_id),
        runtime_lifecycle = CASE
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN 'completed' ELSE excluded.runtime_lifecycle END,
        runtime_evidence = CASE
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN 'runtime_stop_succeeded' ELSE excluded.runtime_evidence END,
        runtime_source_digest = excluded.runtime_source_digest,
        runtime_override_source_digest = CASE
            WHEN agent_workspace_members.runtime_override_source_digest
                 = excluded.runtime_source_digest
            THEN agent_workspace_members.runtime_override_source_digest END,
        last_activity_at = excluded.last_activity_at,
        updated_at = excluded.updated_at
    WHERE excluded.membership_status <> 'historical'
       OR agent_workspace_members.source_session_id = OLD.session_id;

    UPDATE agent_workspace_teams
    SET authority = 'workspace',
        selected_legacy_session_id = CASE
            WHEN selected_legacy_session_id = OLD.session_id THEN NULL
            ELSE selected_legacy_session_id
        END,
        selected_lifecycle = CASE
            WHEN selected_legacy_session_id = OLD.session_id THEN NULL
            ELSE selected_lifecycle
        END,
        source_revision = source_revision + 1,
        shadow_digest = '', updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_legacy_sessions
        WHERE session_id = OLD.session_id
    );
END;

UPDATE schema_meta SET value = '64' WHERE key = 'version';
