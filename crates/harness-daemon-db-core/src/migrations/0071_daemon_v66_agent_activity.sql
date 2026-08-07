CREATE TABLE IF NOT EXISTS agent_workspace_activity_state (
    workspace_id         TEXT PRIMARY KEY
                         REFERENCES agent_workspace_teams(workspace_id) ON DELETE CASCADE,
    source_revision      INTEGER NOT NULL DEFAULT 1 CHECK (source_revision >= 0),
    reconciled_revision  INTEGER NOT NULL DEFAULT 0 CHECK (reconciled_revision >= 0),
    shadow_digest        TEXT NOT NULL DEFAULT '',
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS agent_workspace_activity_sources (
    workspace_id      TEXT NOT NULL
                      REFERENCES agent_workspace_activity_state(workspace_id) ON DELETE CASCADE,
    source_session_id TEXT NOT NULL,
    status            TEXT NOT NULL CHECK (status IN ('active', 'detached')),
    linked_at         TEXT NOT NULL,
    detached_at       TEXT,
    PRIMARY KEY (workspace_id, source_session_id)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_agent_workspace_activity_sources_session
    ON agent_workspace_activity_sources(source_session_id, workspace_id);

CREATE TABLE IF NOT EXISTS agent_workspace_signals (
    workspace_id      TEXT NOT NULL,
    member_id         TEXT NOT NULL,
    signal_id         TEXT NOT NULL,
    runtime           TEXT NOT NULL,
    status            TEXT NOT NULL CHECK (status IN (
                          'pending', 'delivered', 'rejected', 'deferred', 'expired'
                      )),
    signal_json       TEXT NOT NULL,
    ack_json          TEXT,
    origin_kind       TEXT NOT NULL CHECK (origin_kind IN ('legacy', 'native')),
    source_session_id TEXT,
    source_agent_id   TEXT,
    source_digest     TEXT NOT NULL,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL,
    PRIMARY KEY (workspace_id, signal_id),
    FOREIGN KEY (workspace_id, member_id)
        REFERENCES agent_workspace_members(workspace_id, member_id) ON DELETE CASCADE,
    CHECK (
        origin_kind = 'native'
        OR (source_session_id IS NOT NULL AND source_agent_id IS NOT NULL)
    )
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_agent_workspace_signals_member
    ON agent_workspace_signals(workspace_id, member_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_workspace_signals_source
    ON agent_workspace_signals(source_session_id, source_agent_id, workspace_id);

CREATE TABLE IF NOT EXISTS agent_workspace_conversation_events (
    workspace_id      TEXT NOT NULL,
    member_id         TEXT NOT NULL,
    stream_id         TEXT NOT NULL,
    sequence          INTEGER NOT NULL,
    runtime           TEXT NOT NULL,
    timestamp         TEXT,
    kind              TEXT NOT NULL,
    event_json        TEXT NOT NULL,
    origin_kind       TEXT NOT NULL CHECK (origin_kind IN ('legacy', 'native')),
    source_session_id TEXT,
    source_agent_id   TEXT,
    source_digest     TEXT NOT NULL,
    recorded_at       TEXT NOT NULL,
    updated_at        TEXT NOT NULL,
    PRIMARY KEY (workspace_id, member_id, stream_id, sequence),
    FOREIGN KEY (workspace_id, member_id)
        REFERENCES agent_workspace_members(workspace_id, member_id) ON DELETE CASCADE,
    CHECK (
        origin_kind = 'native'
        OR (source_session_id IS NOT NULL AND source_agent_id IS NOT NULL)
    )
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_agent_workspace_conversation_member_time
    ON agent_workspace_conversation_events(
        workspace_id, member_id, recorded_at, sequence
    );
CREATE INDEX IF NOT EXISTS idx_agent_workspace_conversation_source
    ON agent_workspace_conversation_events(
        source_session_id, source_agent_id, workspace_id
    );

CREATE TABLE IF NOT EXISTS agent_workspace_activity_summaries (
    workspace_id      TEXT NOT NULL,
    member_id         TEXT NOT NULL,
    runtime           TEXT NOT NULL,
    activity_json     TEXT NOT NULL,
    origin_kind       TEXT NOT NULL CHECK (origin_kind IN ('legacy', 'native')),
    source_session_id TEXT,
    source_agent_id   TEXT,
    source_digest     TEXT NOT NULL,
    cached_at         TEXT NOT NULL,
    PRIMARY KEY (workspace_id, member_id),
    FOREIGN KEY (workspace_id, member_id)
        REFERENCES agent_workspace_members(workspace_id, member_id) ON DELETE CASCADE,
    CHECK (
        origin_kind = 'native'
        OR (source_session_id IS NOT NULL AND source_agent_id IS NOT NULL)
    )
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS agent_workspace_timeline_entries (
    workspace_id      TEXT NOT NULL
                      REFERENCES agent_workspace_activity_state(workspace_id) ON DELETE CASCADE,
    entry_id          TEXT NOT NULL,
    source_kind       TEXT NOT NULL,
    source_key        TEXT NOT NULL,
    owner_kind        TEXT NOT NULL CHECK (owner_kind IN (
                          'workspace', 'managed_agent', 'work_item', 'review', 'execution'
                      )),
    owner_id          TEXT NOT NULL,
    recorded_at       TEXT NOT NULL,
    kind              TEXT NOT NULL,
    member_id         TEXT,
    legacy_task_id    TEXT,
    summary           TEXT NOT NULL,
    payload_json      TEXT NOT NULL,
    sort_recorded_at  TEXT NOT NULL,
    sort_tiebreaker   TEXT NOT NULL,
    origin_kind       TEXT NOT NULL CHECK (origin_kind IN ('legacy', 'native')),
    source_session_id TEXT,
    source_agent_id   TEXT,
    source_digest     TEXT NOT NULL,
    PRIMARY KEY (workspace_id, source_kind, source_key),
    FOREIGN KEY (workspace_id, member_id)
        REFERENCES agent_workspace_members(workspace_id, member_id) ON DELETE CASCADE,
    CHECK (
        (owner_kind = 'managed_agent' AND member_id IS NOT NULL AND owner_id = member_id)
        OR owner_kind <> 'managed_agent'
    ),
    CHECK (origin_kind = 'native' OR source_session_id IS NOT NULL)
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_workspace_timeline_entry_id
    ON agent_workspace_timeline_entries(workspace_id, entry_id);
CREATE INDEX IF NOT EXISTS idx_agent_workspace_timeline_sort
    ON agent_workspace_timeline_entries(
        workspace_id, sort_recorded_at DESC, sort_tiebreaker DESC
    );
CREATE INDEX IF NOT EXISTS idx_agent_workspace_timeline_owner
    ON agent_workspace_timeline_entries(workspace_id, owner_kind, owner_id);
CREATE INDEX IF NOT EXISTS idx_agent_workspace_timeline_source
    ON agent_workspace_timeline_entries(source_session_id, workspace_id);

CREATE TABLE IF NOT EXISTS agent_workspace_timeline_state (
    workspace_id         TEXT PRIMARY KEY
                         REFERENCES agent_workspace_activity_state(workspace_id) ON DELETE CASCADE,
    revision             INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
    entry_count          INTEGER NOT NULL DEFAULT 0 CHECK (entry_count >= 0),
    newest_recorded_at   TEXT,
    oldest_recorded_at   TEXT,
    integrity_hash       TEXT NOT NULL DEFAULT '',
    updated_at           TEXT NOT NULL
) WITHOUT ROWID;

INSERT INTO agent_workspace_activity_state (
    workspace_id, source_revision, reconciled_revision, shadow_digest,
    created_at, updated_at
)
SELECT workspace_id, 1, 0, '', created_at, updated_at
FROM agent_workspace_teams
WHERE TRUE
ON CONFLICT(workspace_id) DO NOTHING;

INSERT INTO agent_workspace_timeline_state (
    workspace_id, revision, entry_count, newest_recorded_at,
    oldest_recorded_at, integrity_hash, updated_at
)
SELECT workspace_id, 0, 0, NULL, NULL, '', updated_at
FROM agent_workspace_activity_state
WHERE TRUE
ON CONFLICT(workspace_id) DO NOTHING;

INSERT INTO agent_workspace_activity_sources (
    workspace_id, source_session_id, status, linked_at, detached_at
)
SELECT link.workspace_id, link.session_id,
       CASE WHEN session.session_id IS NULL THEN 'detached' ELSE 'active' END,
       workspace.created_at,
       CASE WHEN session.session_id IS NULL THEN datetime('now') END
FROM agent_workspace_legacy_sessions link
JOIN agent_workspace_activity_state workspace ON workspace.workspace_id = link.workspace_id
LEFT JOIN sessions session ON session.session_id = link.session_id
WHERE TRUE
ON CONFLICT(workspace_id, source_session_id) DO NOTHING;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_team_insert
AFTER INSERT ON agent_workspace_teams
BEGIN
    INSERT INTO agent_workspace_activity_state (
        workspace_id, source_revision, reconciled_revision, shadow_digest,
        created_at, updated_at
    ) VALUES (NEW.workspace_id, 1, 0, '', NEW.created_at, NEW.updated_at)
    ON CONFLICT(workspace_id) DO NOTHING;
    INSERT INTO agent_workspace_timeline_state (
        workspace_id, revision, entry_count, newest_recorded_at,
        oldest_recorded_at, integrity_hash, updated_at
    ) VALUES (NEW.workspace_id, 0, 0, NULL, NULL, '', NEW.updated_at)
    ON CONFLICT(workspace_id) DO NOTHING;
    INSERT INTO agent_workspace_activity_sources (
        workspace_id, source_session_id, status, linked_at, detached_at
    )
    SELECT link.workspace_id, link.session_id,
           CASE WHEN session.session_id IS NULL THEN 'detached' ELSE 'active' END,
           NEW.created_at,
           CASE WHEN session.session_id IS NULL THEN datetime('now') END
    FROM agent_workspace_legacy_sessions link
    LEFT JOIN sessions session ON session.session_id = link.session_id
    WHERE link.workspace_id = NEW.workspace_id
    ON CONFLICT(workspace_id, source_session_id) DO NOTHING;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_source_link_insert
AFTER INSERT ON agent_workspace_legacy_sessions
BEGIN
    INSERT INTO agent_workspace_activity_sources (
        workspace_id, source_session_id, status, linked_at, detached_at
    )
    SELECT NEW.workspace_id, NEW.session_id, 'active', datetime('now'), NULL
    FROM agent_workspace_activity_state
    WHERE workspace_id = NEW.workspace_id
    ON CONFLICT(workspace_id, source_session_id) DO UPDATE SET
        status = 'active', detached_at = NULL;
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = NEW.workspace_id;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_source_link_delete
AFTER DELETE ON agent_workspace_legacy_sessions
BEGIN
    UPDATE agent_workspace_activity_sources
    SET status = 'detached', detached_at = COALESCE(detached_at, datetime('now'))
    WHERE workspace_id = OLD.workspace_id AND source_session_id = OLD.session_id;
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = OLD.workspace_id;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_member_provenance_insert
AFTER INSERT ON agent_workspace_member_provenance
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = NEW.workspace_id;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_member_provenance_update
AFTER UPDATE ON agent_workspace_member_provenance
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (OLD.workspace_id, NEW.workspace_id);
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_member_provenance_delete
AFTER DELETE ON agent_workspace_member_provenance
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id = OLD.workspace_id;
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_signal_insert
AFTER INSERT ON signal_index
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = NEW.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_signal_update
AFTER UPDATE ON signal_index
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id IN (OLD.session_id, NEW.session_id) AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_signal_delete
AFTER DELETE ON signal_index
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = OLD.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_conversation_insert
AFTER INSERT ON conversation_events
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = NEW.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_conversation_update
AFTER UPDATE ON conversation_events
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id IN (OLD.session_id, NEW.session_id) AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_conversation_delete
AFTER DELETE ON conversation_events
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = OLD.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_summary_insert
AFTER INSERT ON agent_activity_cache
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = NEW.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_summary_update
AFTER UPDATE ON agent_activity_cache
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id IN (OLD.session_id, NEW.session_id) AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_summary_delete
AFTER DELETE ON agent_activity_cache
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = OLD.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_timeline_insert
AFTER INSERT ON session_timeline_entries
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = NEW.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_timeline_update
AFTER UPDATE ON session_timeline_entries
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id IN (OLD.session_id, NEW.session_id) AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_timeline_delete
AFTER DELETE ON session_timeline_entries
BEGIN
    UPDATE agent_workspace_activity_state
    SET source_revision = source_revision + 1, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = OLD.session_id AND status = 'active'
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_detach_session_guard
BEFORE DELETE ON sessions
BEGIN
    SELECT RAISE(
        ABORT,
        'cannot detach Session before agent activity reconciliation'
    )
    WHERE EXISTS (
        SELECT 1
        FROM agent_workspace_activity_sources source
        JOIN agent_workspace_activity_state state ON state.workspace_id = source.workspace_id
        WHERE source.source_session_id = OLD.session_id
          AND source.status = 'active'
          AND state.source_revision <> state.reconciled_revision
    );

    SELECT RAISE(
        ABORT,
        'cannot detach Session with unmapped agent activity'
    )
    WHERE EXISTS (
        SELECT 1 FROM signal_index signal
        WHERE signal.session_id = OLD.session_id
          AND NOT EXISTS (
              SELECT 1 FROM agent_workspace_member_provenance provenance
              WHERE provenance.source_session_id = signal.session_id
                AND provenance.source_agent_id = signal.agent_id
          )
        UNION ALL
        SELECT 1 FROM conversation_events event
        WHERE event.session_id = OLD.session_id
          AND NOT EXISTS (
              SELECT 1 FROM agent_workspace_member_provenance provenance
              WHERE provenance.source_session_id = event.session_id
                AND provenance.source_agent_id = event.agent_id
          )
        UNION ALL
        SELECT 1 FROM agent_activity_cache activity
        WHERE activity.session_id = OLD.session_id
          AND NOT EXISTS (
              SELECT 1 FROM agent_workspace_member_provenance provenance
              WHERE provenance.source_session_id = activity.session_id
                AND provenance.source_agent_id = activity.agent_id
          )
        UNION ALL
        SELECT 1 FROM session_timeline_entries entry
        WHERE entry.session_id = OLD.session_id
          AND entry.agent_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM agent_workspace_member_provenance provenance
              WHERE provenance.source_session_id = entry.session_id
                AND provenance.source_agent_id = entry.agent_id
          )
    );
END;

CREATE TRIGGER IF NOT EXISTS agent_workspace_activity_detach_session
AFTER DELETE ON sessions
BEGIN
    DELETE FROM signal_index WHERE session_id = OLD.session_id;
    DELETE FROM conversation_events WHERE session_id = OLD.session_id;
    DELETE FROM agent_activity_cache WHERE session_id = OLD.session_id;
    UPDATE agent_workspace_activity_sources
    SET status = 'detached', detached_at = COALESCE(detached_at, datetime('now'))
    WHERE source_session_id = OLD.session_id;
    UPDATE agent_workspace_activity_state
    SET reconciled_revision = source_revision, updated_at = datetime('now')
    WHERE workspace_id IN (
        SELECT workspace_id FROM agent_workspace_activity_sources
        WHERE source_session_id = OLD.session_id
    );
END;

UPDATE schema_meta SET value = '66' WHERE key = 'version';
