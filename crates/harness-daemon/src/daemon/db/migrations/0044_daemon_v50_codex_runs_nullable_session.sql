-- `codex_runs.session_id` was `NOT NULL REFERENCES sessions(session_id)
-- ON DELETE CASCADE` since the v7 baseline, on the assumption every Codex
-- run belongs to a real Harness session. The triage escalation executor
-- breaks that assumption: it spawns a standalone, session-free report run
-- (see `CodexControllerHandle::prepare_standalone_run`), which has no
-- sessions-table row to reference. Making the column nullable -- while
-- keeping `ON DELETE CASCADE` for the session-bound case -- lets a
-- standalone run store an honest NULL instead of a fake session id that
-- would violate the foreign key. `ON DELETE CASCADE` is preserved rather
-- than switched to `ON DELETE SET NULL` so a real session's delete
-- semantics for its own runs are unchanged; a NULL row simply has no FK
-- target to cascade from.
ALTER TABLE codex_runs RENAME TO codex_runs_v50;

CREATE TABLE IF NOT EXISTS codex_runs (
    run_id                  TEXT PRIMARY KEY,
    session_id              TEXT REFERENCES sessions(session_id) ON DELETE CASCADE,
    task_id                 TEXT,
    board_item_id           TEXT,
    workflow_execution_id   TEXT,
    session_agent_id        TEXT,
    display_name            TEXT,
    project_dir             TEXT NOT NULL,
    thread_id               TEXT,
    turn_id                 TEXT,
    mode                    TEXT NOT NULL,
    status                  TEXT NOT NULL,
    prompt                  TEXT NOT NULL,
    latest_summary          TEXT,
    final_message           TEXT,
    error                   TEXT,
    pending_approvals_json  TEXT NOT NULL DEFAULT '[]',
    resolved_approvals_json TEXT NOT NULL DEFAULT '[]',
    events_json             TEXT NOT NULL DEFAULT '[]',
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    model                   TEXT,
    effort                  TEXT
) WITHOUT ROWID;

INSERT INTO codex_runs (
    run_id, session_id, task_id, board_item_id, workflow_execution_id,
    session_agent_id, display_name, project_dir, thread_id, turn_id, mode,
    status, prompt, latest_summary, final_message, error,
    pending_approvals_json, resolved_approvals_json, events_json,
    created_at, updated_at, model, effort
)
SELECT run_id, session_id, task_id, board_item_id, workflow_execution_id,
       session_agent_id, display_name, project_dir, thread_id, turn_id, mode,
       status, prompt, latest_summary, final_message, error,
       pending_approvals_json, resolved_approvals_json, events_json,
       created_at, updated_at, model, effort
FROM codex_runs_v50;

DROP TABLE codex_runs_v50;

CREATE INDEX IF NOT EXISTS idx_codex_runs_session_updated
    ON codex_runs(session_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_codex_runs_status
    ON codex_runs(status);

UPDATE schema_meta SET value = '50' WHERE key = 'version';
