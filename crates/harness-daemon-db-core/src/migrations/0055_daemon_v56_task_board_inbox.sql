UPDATE task_board_items
SET status = 'inbox'
WHERE status = 'backlog';

UPDATE task_board_external_refs
SET sync_state_json = json_set(sync_state_json, '$.status', 'inbox')
WHERE json_valid(sync_state_json)
  AND json_extract(sync_state_json, '$.status') = 'backlog';

UPDATE task_board_sync_conflicts
SET base_value_json = json_quote('inbox')
WHERE field = 'status'
  AND json_valid(base_value_json)
  AND json_extract(base_value_json, '$') = 'backlog';

UPDATE task_board_sync_conflicts
SET local_value_json = json_quote('inbox')
WHERE field = 'status'
  AND json_valid(local_value_json)
  AND json_extract(local_value_json, '$') = 'backlog';

UPDATE task_board_sync_conflicts
SET remote_value_json = json_quote('inbox')
WHERE field = 'status'
  AND json_valid(remote_value_json)
  AND json_extract(remote_value_json, '$') = 'backlog';

UPDATE schema_meta SET value = '56' WHERE key = 'version';
