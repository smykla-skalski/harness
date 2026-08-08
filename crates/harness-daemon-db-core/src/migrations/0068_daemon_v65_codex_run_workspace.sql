-- `codex_runs.session_id` already accepts NULL for standalone report runs, so a
-- board-dispatched run only needs the workspace half of the ownership pair.
-- No CHECK pairing the two: a standalone triage run legitimately has neither.
ALTER TABLE codex_runs
    ADD COLUMN workspace_id TEXT
    REFERENCES agent_workspaces(workspace_id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_codex_runs_workspace_updated
    ON codex_runs(workspace_id, updated_at DESC);
