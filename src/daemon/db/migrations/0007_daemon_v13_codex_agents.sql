ALTER TABLE codex_runs ADD COLUMN session_agent_id TEXT;
ALTER TABLE codex_runs ADD COLUMN display_name TEXT;
ALTER TABLE codex_runs ADD COLUMN model TEXT;
ALTER TABLE codex_runs ADD COLUMN effort TEXT;
ALTER TABLE codex_runs ADD COLUMN resolved_approvals_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE codex_runs ADD COLUMN events_json TEXT NOT NULL DEFAULT '[]';

UPDATE schema_meta SET value = '13' WHERE key = 'version';
