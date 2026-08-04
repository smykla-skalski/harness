UPDATE task_board_items
SET status = 'backlog'
WHERE status = 'umbrella';

UPDATE task_board_external_refs
SET sync_state_json = json_set(sync_state_json, '$.status', 'backlog')
WHERE json_valid(sync_state_json)
  AND json_extract(sync_state_json, '$.status') = 'umbrella';

UPDATE task_board_orchestrator_settings
SET settings_json = json_set(settings_json, '$.dispatch_status_filter', 'backlog')
WHERE json_valid(settings_json)
  AND json_extract(settings_json, '$.dispatch_status_filter') = 'umbrella';

UPDATE task_board_orchestrator_runs
SET scope_json = json_set(scope_json, '$.status', 'backlog')
WHERE json_valid(scope_json)
  AND json_extract(scope_json, '$.status') = 'umbrella';

WITH RECURSIVE
status_paths(singleton, ordinal, path) AS (
    SELECT state.singleton,
           ROW_NUMBER() OVER (PARTITION BY state.singleton ORDER BY tree.fullkey),
           tree.fullkey
    FROM task_board_orchestrator_state AS state,
         json_tree(state.state_json) AS tree
    WHERE json_valid(state.state_json)
      AND tree.type = 'text'
      AND tree.value = 'umbrella'
      AND tree.key IN ('status', 'board_status', 'from_status', 'to_status')
),
rewritten(singleton, ordinal, state_json) AS (
    SELECT singleton, 0, state_json
    FROM task_board_orchestrator_state
    UNION ALL
    SELECT rewritten.singleton,
           rewritten.ordinal + 1,
           json_set(rewritten.state_json, status_paths.path, 'backlog')
    FROM rewritten
    JOIN status_paths
      ON status_paths.singleton = rewritten.singleton
     AND status_paths.ordinal = rewritten.ordinal + 1
)
UPDATE task_board_orchestrator_state
SET state_json = (
    SELECT rewritten.state_json
    FROM rewritten
    WHERE rewritten.singleton = task_board_orchestrator_state.singleton
    ORDER BY rewritten.ordinal DESC
    LIMIT 1
)
WHERE EXISTS (
    SELECT 1
    FROM status_paths
    WHERE status_paths.singleton = task_board_orchestrator_state.singleton
);

WITH RECURSIVE
status_paths(intent_id, ordinal, path) AS (
    SELECT intent.intent_id,
           ROW_NUMBER() OVER (PARTITION BY intent.intent_id ORDER BY tree.fullkey),
           tree.fullkey
    FROM task_board_dispatch_intents AS intent,
         json_tree(intent.payload_json) AS tree
    WHERE json_valid(intent.payload_json)
      AND tree.type = 'text'
      AND tree.value = 'umbrella'
      AND tree.key IN ('status', 'board_status', 'from_status', 'to_status')
),
rewritten(intent_id, ordinal, payload_json) AS (
    SELECT intent_id, 0, payload_json
    FROM task_board_dispatch_intents
    UNION ALL
    SELECT rewritten.intent_id,
           rewritten.ordinal + 1,
           json_set(rewritten.payload_json, status_paths.path, 'backlog')
    FROM rewritten
    JOIN status_paths
      ON status_paths.intent_id = rewritten.intent_id
     AND status_paths.ordinal = rewritten.ordinal + 1
)
UPDATE task_board_dispatch_intents
SET payload_json = (
    SELECT rewritten.payload_json
    FROM rewritten
    WHERE rewritten.intent_id = task_board_dispatch_intents.intent_id
    ORDER BY rewritten.ordinal DESC
    LIMIT 1
)
WHERE EXISTS (
    SELECT 1
    FROM status_paths
    WHERE status_paths.intent_id = task_board_dispatch_intents.intent_id
);

WITH RECURSIVE
status_paths(run_id, ordinal, path) AS (
    SELECT run.run_id,
           ROW_NUMBER() OVER (PARTITION BY run.run_id ORDER BY tree.fullkey),
           tree.fullkey
    FROM task_board_orchestrator_runs AS run,
         json_tree(run.stage_summary_json) AS tree
    WHERE json_valid(run.stage_summary_json)
      AND tree.type = 'text'
      AND tree.value = 'umbrella'
      AND tree.key IN ('status', 'board_status', 'from_status', 'to_status')
),
rewritten(run_id, ordinal, stage_summary_json) AS (
    SELECT run_id, 0, stage_summary_json
    FROM task_board_orchestrator_runs
    UNION ALL
    SELECT rewritten.run_id,
           rewritten.ordinal + 1,
           json_set(rewritten.stage_summary_json, status_paths.path, 'backlog')
    FROM rewritten
    JOIN status_paths
      ON status_paths.run_id = rewritten.run_id
     AND status_paths.ordinal = rewritten.ordinal + 1
)
UPDATE task_board_orchestrator_runs
SET stage_summary_json = (
    SELECT rewritten.stage_summary_json
    FROM rewritten
    WHERE rewritten.run_id = task_board_orchestrator_runs.run_id
    ORDER BY rewritten.ordinal DESC
    LIMIT 1
)
WHERE EXISTS (
    SELECT 1
    FROM status_paths
    WHERE status_paths.run_id = task_board_orchestrator_runs.run_id
);

UPDATE task_board_sync_conflicts
SET base_value_json = json_quote('backlog')
WHERE field = 'status'
  AND json_valid(base_value_json)
  AND json_extract(base_value_json, '$') = 'umbrella';

UPDATE task_board_sync_conflicts
SET local_value_json = json_quote('backlog')
WHERE field = 'status'
  AND json_valid(local_value_json)
  AND json_extract(local_value_json, '$') = 'umbrella';

UPDATE task_board_sync_conflicts
SET remote_value_json = json_quote('backlog')
WHERE field = 'status'
  AND json_valid(remote_value_json)
  AND json_extract(remote_value_json, '$') = 'umbrella';

UPDATE schema_meta SET value = '37' WHERE key = 'version';
