ALTER TABLE tasks ADD COLUMN awaiting_review_queued_at TEXT;
ALTER TABLE tasks ADD COLUMN awaiting_review_submitter_agent_id TEXT;
ALTER TABLE tasks ADD COLUMN awaiting_review_required_consensus INTEGER NOT NULL DEFAULT 2;
ALTER TABLE tasks ADD COLUMN review_round INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tasks ADD COLUMN review_claim_json TEXT;
ALTER TABLE tasks ADD COLUMN consensus_json TEXT;
ALTER TABLE tasks ADD COLUMN arbitration_json TEXT;
ALTER TABLE tasks ADD COLUMN suggested_persona TEXT;
CREATE TABLE IF NOT EXISTS task_reviews (
    review_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    round INTEGER NOT NULL,
    reviewer_agent_id TEXT NOT NULL,
    reviewer_runtime TEXT NOT NULL,
    verdict TEXT NOT NULL,
    summary TEXT NOT NULL,
    points_json TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_reviews_task ON task_reviews(session_id, task_id);
UPDATE schema_meta SET value = '10' WHERE key = 'version';
