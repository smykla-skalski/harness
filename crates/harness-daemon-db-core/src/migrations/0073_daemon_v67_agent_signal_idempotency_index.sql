CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_workspace_signals_native_idempotency
    ON agent_workspace_signals(workspace_id, member_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
