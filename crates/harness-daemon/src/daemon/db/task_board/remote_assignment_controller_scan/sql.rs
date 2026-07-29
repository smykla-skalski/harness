pub(super) const SCAN_CYCLE_MAX: &str = "SELECT assignments.assignment_id,
           assignments.offered_at AS order_at, assignments.fencing_epoch,
           assignments.state AS assignment_state,
           assignments.updated_at AS assignment_updated_at,
           assignments.request_sha256, assignments.lease_id
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    LEFT JOIN task_board_remote_recovery_quarantine AS quarantine
      ON quarantine.assignment_id = assignments.assignment_id
    WHERE hosts.host_role = 'controller_remote'
      AND assignments.legacy_migrated = 0
      AND (quarantine.assignment_id IS NULL
           OR quarantine.fencing_epoch != assignments.fencing_epoch
           OR quarantine.assignment_state != assignments.state
           OR quarantine.assignment_updated_at != assignments.updated_at
           OR quarantine.next_attempt_at <= ?1)
      AND (
          assignments.state IN ('offered', 'claimed', 'started', 'running')
          OR (assignments.state IN ('completed', 'failed', 'cancelled', 'unknown')
              AND assignments.cleanup_completed_at IS NULL)
          -- A local_fallback or remote_reassigned superseded generation was never durably
          -- claimed, so it has no executor workspace to settle; its handoff already
          -- advanced the parent and it must leave the cleanup scan (retention prunes it).
          OR (assignments.state = 'superseded' AND assignments.lease_id IS NOT NULL
              AND assignments.cleanup_completed_at IS NULL
              AND (assignments.controller_handoff_kind IS NULL
                   OR assignments.controller_handoff_kind NOT IN
                      ('local_fallback', 'remote_reassigned')))
      )
    ORDER BY assignments.offered_at DESC, assignments.assignment_id DESC LIMIT 1";

pub(super) const SCAN_CYCLE_FROM_START: &str = "SELECT assignments.assignment_id,
           assignments.offered_at AS order_at, assignments.fencing_epoch,
           assignments.state AS assignment_state,
           assignments.updated_at AS assignment_updated_at,
           assignments.request_sha256, assignments.lease_id
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    LEFT JOIN task_board_remote_recovery_quarantine AS quarantine
      ON quarantine.assignment_id = assignments.assignment_id
    WHERE hosts.host_role = 'controller_remote'
      AND assignments.legacy_migrated = 0
      AND (quarantine.assignment_id IS NULL
           OR quarantine.fencing_epoch != assignments.fencing_epoch
           OR quarantine.assignment_state != assignments.state
           OR quarantine.assignment_updated_at != assignments.updated_at
           OR quarantine.next_attempt_at <= ?1)
      AND (
          assignments.state IN ('offered', 'claimed', 'started', 'running')
          OR (assignments.state IN ('completed', 'failed', 'cancelled', 'unknown')
              AND assignments.cleanup_completed_at IS NULL)
          -- A local_fallback or remote_reassigned superseded generation was never durably
          -- claimed, so it has no executor workspace to settle; its handoff already
          -- advanced the parent and it must leave the cleanup scan (retention prunes it).
          OR (assignments.state = 'superseded' AND assignments.lease_id IS NOT NULL
              AND assignments.cleanup_completed_at IS NULL
              AND (assignments.controller_handoff_kind IS NULL
                   OR assignments.controller_handoff_kind NOT IN
                      ('local_fallback', 'remote_reassigned')))
      )
      AND (assignments.offered_at < ?2
           OR (assignments.offered_at = ?2 AND assignments.assignment_id <= ?3))
    ORDER BY assignments.offered_at, assignments.assignment_id LIMIT ?4";

pub(super) const SCAN_CYCLE_AFTER: &str = "SELECT assignments.assignment_id,
           assignments.offered_at AS order_at, assignments.fencing_epoch,
           assignments.state AS assignment_state,
           assignments.updated_at AS assignment_updated_at,
           assignments.request_sha256, assignments.lease_id
    FROM task_board_remote_assignments AS assignments
    JOIN task_board_execution_hosts AS hosts ON hosts.host_id = assignments.host_id
    LEFT JOIN task_board_remote_recovery_quarantine AS quarantine
      ON quarantine.assignment_id = assignments.assignment_id
    WHERE hosts.host_role = 'controller_remote'
      AND assignments.legacy_migrated = 0
      AND (quarantine.assignment_id IS NULL
           OR quarantine.fencing_epoch != assignments.fencing_epoch
           OR quarantine.assignment_state != assignments.state
           OR quarantine.assignment_updated_at != assignments.updated_at
           OR quarantine.next_attempt_at <= ?1)
      AND (
          assignments.state IN ('offered', 'claimed', 'started', 'running')
          OR (assignments.state IN ('completed', 'failed', 'cancelled', 'unknown')
              AND assignments.cleanup_completed_at IS NULL)
          -- A local_fallback or remote_reassigned superseded generation was never durably
          -- claimed, so it has no executor workspace to settle; its handoff already
          -- advanced the parent and it must leave the cleanup scan (retention prunes it).
          OR (assignments.state = 'superseded' AND assignments.lease_id IS NOT NULL
              AND assignments.cleanup_completed_at IS NULL
              AND (assignments.controller_handoff_kind IS NULL
                   OR assignments.controller_handoff_kind NOT IN
                      ('local_fallback', 'remote_reassigned')))
      )
      AND (assignments.offered_at > ?2
           OR (assignments.offered_at = ?2 AND assignments.assignment_id > ?3))
      AND (assignments.offered_at < ?4
           OR (assignments.offered_at = ?4 AND assignments.assignment_id <= ?5))
    ORDER BY assignments.offered_at, assignments.assignment_id LIMIT ?6";
