use super::{
    CONTROLLER_SCAN_LIMIT, TaskBoardRemoteControllerReport, canonical_now, progress_assignment,
};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteControllerScanItem, TaskBoardRemoteControllerScanStep,
};
use crate::errors::CliError;

pub(super) async fn progress_existing_assignments(
    db: &AsyncDaemonDb,
    report: &mut TaskBoardRemoteControllerReport,
) -> Result<(), CliError> {
    report.scan_incomplete = false;
    for _ in 0..CONTROLLER_SCAN_LIMIT {
        let scan_now = canonical_now();
        let Some(step) = db
            .next_task_board_remote_controller_assignment(&scan_now)
            .await?
        else {
            return Ok(());
        };
        let item = match step {
            TaskBoardRemoteControllerScanStep::Assignment(item) => item,
            TaskBoardRemoteControllerScanStep::Quarantined(failure) => {
                report.failures.push(format!(
                    "remote assignment '{}' scan failed [{}]: {}",
                    failure.assignment_id, failure.code, failure.message
                ));
                report.scan_incomplete = failure.scan_incomplete;
                if !report.scan_incomplete {
                    return Ok(());
                }
                continue;
            }
        };
        let result = Box::pin(progress_assignment(db, item.assignment.clone())).await;
        finish_progress_attempt(db, &item, result, report).await?;
        if !report.scan_incomplete {
            return Ok(());
        }
    }
    Ok(())
}

pub(super) async fn finish_progress_attempt(
    db: &AsyncDaemonDb,
    item: &TaskBoardRemoteControllerScanItem,
    result: Result<bool, CliError>,
    report: &mut TaskBoardRemoteControllerReport,
) -> Result<(), CliError> {
    match result {
        Ok(changed) => {
            db.clear_task_board_remote_controller_progression_quarantine(item)
                .await?;
            report.verified_assignments += 1;
            if changed {
                report.progressed_assignments += 1;
            }
        }
        Err(error) => {
            report
                .blocked_host_ids
                .insert(item.assignment.host_id.clone());
            report.failures.push(format!(
                "remote assignment '{}' progression failed: {error}",
                item.assignment.assignment_id
            ));
            let deferred_at = canonical_now();
            report.scan_incomplete = db
                .defer_task_board_remote_controller_assignment_scan(item, &deferred_at)
                .await?;
            report.scan_blocked = true;
            return Ok(());
        }
    }
    report.scan_incomplete = db
        .complete_task_board_remote_controller_assignment_scan(item, &canonical_now())
        .await?;
    Ok(())
}
