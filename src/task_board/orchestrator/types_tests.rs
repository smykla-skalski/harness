use super::*;

/// A run summary recorded before a provider was removed from the build. The
/// shape is otherwise current, so only the retired variant can fail the parse.
const STATE_WITH_RETIRED_PROVIDER: &str = r#"{
  "schema_version": 1,
  "enabled": true,
  "running": true,
  "last_run": {
    "run_id": "task-board-run-1",
    "started_at": "2026-07-23T09:37:42Z",
    "completed_at": "2026-07-23T09:37:43Z",
    "status": "completed",
    "dry_run": true,
    "sync": {
      "total": 2,
      "providers": [
        {
          "provider": "todoist",
          "configured": false,
          "linked": 0,
          "pushable": 2,
          "blocked": 0,
          "token_env": ["HARNESS_TODOIST_TOKEN"]
        }
      ]
    },
    "audit": { "total": 0, "ready": 0, "blocked": 0, "deleted": 0, "by_status": [] }
  }
}"#;

#[test]
fn a_retired_provider_in_the_last_run_does_not_fail_the_state() {
    let state: TaskBoardOrchestratorState =
        serde_json::from_str(STATE_WITH_RETIRED_PROVIDER).expect("state parses");

    assert!(state.enabled, "live intent survives an unreadable last run");
    assert!(state.running, "live intent survives an unreadable last run");
    assert!(
        state.last_run.is_none(),
        "the unreadable run record is dropped rather than kept half-built"
    );
}

#[test]
fn a_readable_last_run_is_still_kept() {
    let readable = STATE_WITH_RETIRED_PROVIDER.replace("\"todoist\"", "\"github\"");

    let state: TaskBoardOrchestratorState =
        serde_json::from_str(&readable).expect("state parses");

    let last_run = state.last_run.expect("a readable run record is preserved");
    assert_eq!(last_run.run_id, "task-board-run-1");
    assert_eq!(last_run.sync.providers.len(), 1);
}
