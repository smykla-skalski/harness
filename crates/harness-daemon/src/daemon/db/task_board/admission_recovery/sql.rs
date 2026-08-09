// The two branches keep lifetime release history out of the startup hot path:
// active admissions use the partial current-requirement index, while released
// settlement debt starts from the partial active-progress index and probes its
// exact intent.
pub(super) const ADMISSION_RECOVERY_SQL: &str =
    "SELECT DISTINCT ledger.managed_worker_id, intent.intent_id, intent.item_id,
        intent.session_id, intent.workspace_id, intent.working_copy_id,
        intent.work_item_id, intent.workflow_execution_id,
        intent.payload_json, intent.status AS intent_status
     FROM task_board_dispatch_admission_ledger AS ledger
          INDEXED BY task_board_dispatch_admission_ledger_current_requirement
     JOIN task_board_dispatch_intents AS intent ON intent.intent_id = ledger.intent_id
     WHERE ledger.kind = 'concurrency'
       AND ledger.managed_worker_id IS NOT NULL
       AND ledger.state IN ('reserved', 'committed')
       AND ledger.state = 'committed'
       AND NOT (intent.status = 'starting' AND intent.compensation_pending = 1)
     UNION
     SELECT DISTINCT ledger.managed_worker_id, intent.intent_id, intent.item_id,
        intent.session_id, intent.workspace_id, intent.working_copy_id,
        intent.work_item_id, intent.workflow_execution_id,
        intent.payload_json, intent.status AS intent_status
     FROM task_board_work_item_progress AS progress
          INDEXED BY idx_task_board_work_item_progress_recovery
     JOIN task_board_dispatch_intents AS intent
       ON intent.item_id = progress.item_id
      AND intent.work_item_id = progress.work_item_id
     JOIN task_board_dispatch_admission_ledger AS ledger
          INDEXED BY task_board_dispatch_admission_ledger_intent_generation
       ON ledger.intent_id = intent.intent_id
      AND ledger.managed_worker_id = progress.attempt_id
     WHERE progress.completed_at IS NULL
       AND progress.state IN ('pending', 'running')
       AND progress.attempt_id IS NOT NULL
       AND ledger.kind = 'concurrency'
       AND ledger.state = 'released'
       AND ledger.managed_worker_id IS NOT NULL
       AND intent.status = 'completed'
       AND (
           (
               NOT EXISTS (
                   SELECT 1 FROM codex_runs AS run
                   WHERE run.run_id = ledger.managed_worker_id
               )
               AND NOT EXISTS (
                   SELECT 1 FROM agent_tuis AS tui
                   WHERE tui.tui_id = ledger.managed_worker_id
               )
           )
           OR EXISTS (
               SELECT 1 FROM codex_runs AS run
               WHERE run.run_id = ledger.managed_worker_id
                 AND run.status IN ('completed', 'failed', 'cancelled')
           )
           OR EXISTS (
               SELECT 1 FROM agent_tuis AS tui
               WHERE tui.tui_id = ledger.managed_worker_id
                 AND tui.status IN ('exited', 'failed', 'stopped')
           )
       )
     ORDER BY 1, 2";

pub(super) const ADMISSION_RECOVERY_FOR_WORKER_SQL: &str =
    "SELECT DISTINCT ledger.managed_worker_id, intent.intent_id, intent.item_id,
        intent.session_id, intent.workspace_id, intent.working_copy_id,
        intent.work_item_id, intent.workflow_execution_id,
        intent.payload_json, intent.status AS intent_status
     FROM task_board_dispatch_intents AS intent
     JOIN task_board_dispatch_admission_ledger AS ledger ON ledger.intent_id = intent.intent_id
     WHERE intent.intent_id = ?1
       AND ledger.kind = 'concurrency'
       AND ledger.managed_worker_id = ?2
       AND NOT (intent.status = 'starting' AND intent.compensation_pending = 1)
       AND (
           ledger.state = 'committed'
           OR (ledger.state = 'released' AND intent.status = 'completed' AND EXISTS (
               SELECT 1 FROM task_board_work_item_progress AS progress
               WHERE progress.item_id = intent.item_id
                 AND progress.work_item_id = intent.work_item_id
                 AND progress.attempt_id = ledger.managed_worker_id
                 AND progress.completed_at IS NULL
                 AND progress.state IN ('pending', 'running')
                 AND (
                     (
                         NOT EXISTS (
                             SELECT 1 FROM codex_runs AS run
                             WHERE run.run_id = ledger.managed_worker_id
                         )
                         AND NOT EXISTS (
                             SELECT 1 FROM agent_tuis AS tui
                             WHERE tui.tui_id = ledger.managed_worker_id
                         )
                     )
                     OR EXISTS (
                         SELECT 1 FROM codex_runs AS run
                         WHERE run.run_id = ledger.managed_worker_id
                           AND run.status IN ('completed', 'failed', 'cancelled')
                     )
                     OR EXISTS (
                         SELECT 1 FROM agent_tuis AS tui
                         WHERE tui.tui_id = ledger.managed_worker_id
                           AND tui.status IN ('exited', 'failed', 'stopped')
                     )
                 )
           ))
       )
     ORDER BY ledger.managed_worker_id, intent.intent_id";
