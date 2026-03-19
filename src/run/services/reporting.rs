use tracing::warn;

use crate::run::{ExecutedGroupChange, GroupVerdict, RunStatus};
use crate::workspace::utc_now;

pub(crate) fn apply_group_report_result(
    run_status: &mut RunStatus,
    group_id: &str,
    verdict: GroupVerdict,
    capture_label: Option<&str>,
    note: Option<&str>,
) -> bool {
    let state_capture_at_report = run_status.last_state_capture.take();

    if !prepare_group_report_update(
        run_status,
        group_id,
        verdict,
        capture_label,
        state_capture_at_report.as_deref(),
    ) {
        run_status.last_state_capture = state_capture_at_report;
        return false;
    }

    let now = utc_now();
    let change =
        run_status.record_group_result(group_id, verdict, &now, state_capture_at_report.as_deref());
    run_status.last_completed_group = Some(group_id.to_string());
    run_status.last_updated_utc = Some(now);
    run_status.last_state_capture = state_capture_at_report;
    debug_assert_ne!(change, ExecutedGroupChange::Noop);

    if let Some(note) = note {
        run_status.notes.push(note.to_string());
    }

    true
}

fn prepare_group_report_update(
    run_status: &RunStatus,
    group_id: &str,
    verdict: GroupVerdict,
    capture_label: Option<&str>,
    state_capture_at_report: Option<&str>,
) -> bool {
    match run_status.group_verdict(group_id) {
        Some(previous) if previous == verdict => false,
        Some(previous) => {
            warn!(%group_id, %previous, %verdict, "group status updated");
            true
        }
        None => {
            if capture_label.is_none() {
                warn_if_capture_missing_with_state(run_status, state_capture_at_report);
            }
            true
        }
    }
}

fn warn_if_capture_missing_with_state(run_status: &RunStatus, last_state_capture: Option<&str>) {
    if run_status.last_completed_group.is_none() {
        return;
    }

    if last_state_capture == run_status.last_group_capture_value() {
        let previous_group = run_status
            .last_completed_group
            .as_deref()
            .unwrap_or("unknown");
        warn!(
            %previous_group,
            "no state capture between groups - run 'harness run capture' or pass --capture-label"
        );
    }
}

#[cfg(test)]
mod tests {
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
}
