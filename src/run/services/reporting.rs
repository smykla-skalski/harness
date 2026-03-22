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
    if let Some(previous) = run_status.group_verdict(group_id) {
        return previous != verdict;
    }
    let _ = capture_label.is_none()
        && warn_if_capture_missing_with_state(run_status, state_capture_at_report);
    true
}

fn warn_if_capture_missing_with_state(
    run_status: &RunStatus,
    last_state_capture: Option<&str>,
) -> bool {
    run_status.last_completed_group.is_some()
        && last_state_capture == run_status.last_group_capture_value()
}

#[cfg(test)]
#[path = "reporting/tests.rs"]
mod tests;
