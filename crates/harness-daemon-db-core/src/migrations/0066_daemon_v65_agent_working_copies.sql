-- A durable workspace needs a checkout of its own once dispatch stops creating
-- a Session to borrow one from. The rows here are the daemon's record of what
-- it created on disk, so compensation can remove exactly the checkout a failed
-- dispatch made and nothing else.
CREATE TABLE IF NOT EXISTS agent_working_copies (
    working_copy_id TEXT PRIMARY KEY,
    workspace_id    TEXT NOT NULL
                    REFERENCES agent_workspaces(workspace_id) ON DELETE CASCADE,
    origin_path     TEXT NOT NULL,
    project_name    TEXT NOT NULL,
    worktree_path   TEXT NOT NULL,
    branch_ref      TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('active', 'released')),
    released_reason TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    CHECK (status = 'released' OR released_reason IS NULL)
) WITHOUT ROWID;

-- One live checkout per path. A released row keeps its history without blocking
-- the next dispatch that lands on the same directory after cleanup.
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_working_copies_active_path
    ON agent_working_copies(worktree_path)
    WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_agent_working_copies_workspace
    ON agent_working_copies(workspace_id, status);
