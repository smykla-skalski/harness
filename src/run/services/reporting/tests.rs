use crate::run::{ExecutedGroupRecord, RunCounts, Verdict};

use super::*;

fn make_status() -> RunStatus {
    RunStatus {
        run_id: "test-run".to_string(),
        suite_id: "test-suite".to_string(),
        profile: "default".to_string(),
        started_at: "2026-03-16T00:00:00Z".to_string(),
        overall_verdict: Verdict::Pending,
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: vec![],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    }
}

#[test]
fn last_group_capture_value_empty_groups() {
    let status = make_status();
    assert_eq!(status.last_group_capture_value(), None);
}

#[test]
fn last_group_capture_value_with_capture() {
    let mut status = make_status();
    status.executed_groups = vec![ExecutedGroupRecord {
        group_id: "g01".to_string(),
        verdict: GroupVerdict::Pass,
        completed_at: "2026-03-16T00:00:00Z".to_string(),
        state_capture_at_report: Some("state/after-g01.json".to_string()),
    }];
    assert_eq!(
        status.last_group_capture_value(),
        Some("state/after-g01.json")
    );
}

#[test]
fn last_group_capture_value_null_capture() {
    let mut status = make_status();
    status.executed_groups = vec![ExecutedGroupRecord {
        group_id: "g01".to_string(),
        verdict: GroupVerdict::Pass,
        completed_at: "2026-03-16T00:00:00Z".to_string(),
        state_capture_at_report: None,
    }];
    assert_eq!(status.last_group_capture_value(), None);
}

#[test]
fn warn_if_capture_missing_no_previous_group() {
    let status = make_status();
    warn_if_capture_missing_with_state(&status, None);
}

#[test]
fn warn_if_capture_missing_capture_unchanged() {
    let mut status = make_status();
    status.last_completed_group = Some("g01".to_string());
    status.executed_groups = vec![ExecutedGroupRecord {
        group_id: "g01".to_string(),
        verdict: GroupVerdict::Pass,
        completed_at: "2026-03-16T00:00:00Z".to_string(),
        state_capture_at_report: Some("state/capture-1.json".to_string()),
    }];
    warn_if_capture_missing_with_state(&status, Some("state/capture-1.json"));
}

#[test]
fn warn_if_capture_missing_capture_changed() {
    let mut status = make_status();
    status.last_completed_group = Some("g01".to_string());
    status.executed_groups = vec![ExecutedGroupRecord {
        group_id: "g01".to_string(),
        verdict: GroupVerdict::Pass,
        completed_at: "2026-03-16T00:00:00Z".to_string(),
        state_capture_at_report: Some("state/capture-1.json".to_string()),
    }];
    warn_if_capture_missing_with_state(&status, Some("state/capture-2.json"));
}
