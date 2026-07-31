-- Durable record of a non-Codex agent turn (a board report run), keyed by
-- `run_id` which doubles as the task-board `managed_worker_id`. Codex runs
-- already persist through `codex_runs`; every other supported runtime
-- (OpenRouter today) kept no durable row, so a restart could not tell whether
-- a run started, settle one that ended while the daemon was down, or avoid
-- starting it a second time. This table closes that gap with a runtime-generic
-- shape: both the requested and the actual runtime and model are recorded so a
-- restart reconciles each interrupted run to exactly one terminal outcome with
-- no manual intervention.
--
-- No `sessions` foreign key on purpose: a report run is identified by its own
-- `run_id` and may be recorded before or after its session row exists, so it
-- stores `session_id` as an honest nullable label rather than a constrained
-- reference that would force the codex `save`-time existence dance.
--
-- IF NOT EXISTS keeps the statement safe under the sync repair replay, which
-- re-runs every migration step against an already-current database.
CREATE TABLE IF NOT EXISTS agent_turn_runs (
    run_id                TEXT PRIMARY KEY NOT NULL,
    session_id            TEXT,
    task_id               TEXT,
    board_item_id         TEXT,
    workflow_execution_id TEXT,
    project_dir           TEXT,
    requested_runtime     TEXT NOT NULL,
    actual_runtime        TEXT,
    requested_model       TEXT,
    actual_model          TEXT,
    status                TEXT NOT NULL
                              CHECK (status IN (
                                  'queued', 'running', 'completed', 'failed', 'cancelled'
                              )),
    source_revision       TEXT,
    report                TEXT,
    stop_reason           TEXT,
    error                 TEXT,
    created_at            TEXT NOT NULL,
    updated_at            TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agent_turn_runs_session_updated
    ON agent_turn_runs(session_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_turn_runs_status
    ON agent_turn_runs(status);

-- Both migration paths take the stamp from here: the async bootstrap trusts
-- this value rather than re-deriving it, and the sync step is this file alone.
UPDATE schema_meta SET value = '59' WHERE key = 'version';
