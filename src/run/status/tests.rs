use std::fs;

use super::*;

#[test]
fn test_load_run_status() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("run-status.json");
    let json = serde_json::json!({
        "run_id": "t",
        "suite_id": "s",
        "profile": "single-zone",
        "started_at": "now",
        "completed_at": null,
        "executed_groups": [],
        "skipped_groups": [],
        "overall_verdict": "pending",
        "last_state_capture": null,
        "notes": []
    });
    fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

    let status = RunStatus::load(&path).unwrap();
    assert_eq!(status.last_state_capture, None);
    assert_eq!(status.counts, RunCounts::default());
    assert_eq!(status.last_completed_group, None);
    assert_eq!(status.next_planned_group, None);
}

#[test]
fn test_load_run_status_accepts_structured_group_entries() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("run-status.json");
    let json = serde_json::json!({
        "run_id": "t",
        "suite_id": "s",
        "profile": "single-zone",
        "started_at": "now",
        "completed_at": null,
        "counts": {"passed": 1, "failed": 0, "skipped": 0},
        "executed_groups": [
            {
                "group_id": "g02",
                "verdict": "pass",
                "completed_at": "2026-03-14T07:57:19Z"
            }
        ],
        "skipped_groups": [],
        "last_completed_group": "g02",
        "overall_verdict": "pending",
        "last_state_capture": "state/after-g02.json",
        "last_updated_utc": "2026-03-14T07:57:19Z",
        "next_planned_group": "g03",
        "notes": []
    });
    fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

    let status = RunStatus::load(&path).unwrap();
    assert_eq!(
        status.counts,
        RunCounts {
            passed: 1,
            failed: 0,
            skipped: 0,
        }
    );
    assert_eq!(status.executed_group_ids(), vec!["g02"]);
    assert_eq!(status.last_completed_group.as_deref(), Some("g02"));
    assert_eq!(status.next_planned_group.as_deref(), Some("g03"));
}
