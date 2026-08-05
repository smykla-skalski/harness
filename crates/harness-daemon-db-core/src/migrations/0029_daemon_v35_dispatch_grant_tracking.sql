-- Retain the one-shot grant consumed by an immediate dispatch until worker
-- startup succeeds, so a pre-start failure can atomically restore it.
ALTER TABLE task_board_dispatch_intents
    ADD COLUMN consumed_approval_grant_id TEXT;

-- The original v34 migration defaulted this switch open. Close existing v34
-- workspaces when the delivery-time policy recheck ships.
UPDATE policy_workspace SET spawn_requires_live_policy = 1;

UPDATE schema_meta SET value = '35' WHERE key = 'version';
