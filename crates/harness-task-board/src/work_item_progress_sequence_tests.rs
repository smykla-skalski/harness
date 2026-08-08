use super::*;

#[test]
fn out_of_order_report_is_refused() {
    let mut first = report(Some(TaskBoardWorkItemState::Running));
    first.sequence = Some(5);
    let mut stale = report(Some(TaskBoardWorkItemState::AwaitingReview));
    stale.sequence = Some(3);

    let outcome = apply_work_item_report(&applied(&progress(), &first), &stale);

    assert_eq!(
        outcome.rejection(),
        Some(TaskBoardWorkItemReportRejection::StaleSequence)
    );
    assert_eq!(outcome.progress().state, TaskBoardWorkItemState::Running);
    assert_eq!(outcome.progress().report_sequence, 5);
}

#[test]
fn replayed_sequence_is_refused() {
    let mut first = report(Some(TaskBoardWorkItemState::Running));
    first.sequence = Some(1);
    let applied_once = applied(&progress(), &first);

    let outcome = apply_work_item_report(&applied_once, &first);

    assert_eq!(
        outcome.rejection(),
        Some(TaskBoardWorkItemReportRejection::StaleSequence)
    );
    assert_eq!(outcome.progress().checkpoints.len(), 0);
}

#[test]
fn exhausted_sequence_refuses_another_non_terminal_report() {
    let mut current = progress();
    current.state = TaskBoardWorkItemState::Running;
    current.report_sequence = TASK_BOARD_WORK_ITEM_REPORT_SEQUENCE_MAX - 1;

    let outcome = apply_work_item_report(&current, &report(None));

    assert_eq!(
        outcome.rejection(),
        Some(TaskBoardWorkItemReportRejection::SequenceExhausted)
    );
    assert_eq!(outcome.progress(), &current);
}

#[test]
fn last_sequence_can_freeze_the_record() {
    let mut current = progress();
    current.state = TaskBoardWorkItemState::Running;
    current.report_sequence = TASK_BOARD_WORK_ITEM_REPORT_SEQUENCE_MAX - 1;

    let updated = applied(&current, &report(Some(TaskBoardWorkItemState::Done)));

    assert_eq!(
        updated.report_sequence,
        TASK_BOARD_WORK_ITEM_REPORT_SEQUENCE_MAX
    );
    assert_eq!(updated.state, TaskBoardWorkItemState::Done);
}

#[test]
fn client_cannot_claim_the_reserved_terminal_fence() {
    let mut report = report(Some(TaskBoardWorkItemState::Done));
    report.sequence = Some(TASK_BOARD_WORK_ITEM_REPORT_SEQUENCE_MAX);

    let outcome = apply_work_item_report(&progress(), &report);

    assert_eq!(
        outcome.rejection(),
        Some(TaskBoardWorkItemReportRejection::SequenceExhausted)
    );
}
