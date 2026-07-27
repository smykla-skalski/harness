use super::*;

#[test]
fn external_status_reconciliation_preserves_workflow_and_tracks_provider_terminality() {
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::InProgress,
            Some(TaskBoardStatus::Inbox),
            TaskBoardStatus::Inbox,
        ),
        TaskBoardStatus::InProgress
    );
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::Inbox,
            Some(TaskBoardStatus::Inbox),
            TaskBoardStatus::Done,
        ),
        TaskBoardStatus::Done
    );
    for observed in [TaskBoardStatus::Inbox, TaskBoardStatus::Done] {
        assert_eq!(
            reconciled_external_status(
                TaskBoardStatus::InProgress,
                Some(TaskBoardStatus::InProgress),
                observed,
            ),
            TaskBoardStatus::InProgress
        );
    }
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::Done,
            Some(TaskBoardStatus::Done),
            TaskBoardStatus::Inbox,
        ),
        TaskBoardStatus::Inbox
    );
    for last_synced in [TaskBoardStatus::Todo, TaskBoardStatus::Inbox] {
        assert_eq!(
            reconciled_external_status(
                TaskBoardStatus::Todo,
                Some(last_synced),
                TaskBoardStatus::Inbox,
            ),
            TaskBoardStatus::Todo
        );
    }
    for current in [TaskBoardStatus::Todo, TaskBoardStatus::Inbox] {
        assert_eq!(
            reconciled_external_status(current, None, TaskBoardStatus::Done),
            TaskBoardStatus::Done
        );
        assert_eq!(
            reconciled_external_status(current, Some(TaskBoardStatus::Done), TaskBoardStatus::Done,),
            current
        );
    }
    assert_eq!(
        reconciled_external_status(TaskBoardStatus::InProgress, None, TaskBoardStatus::Done),
        TaskBoardStatus::InProgress
    );
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::Done,
            Some(TaskBoardStatus::Inbox),
            TaskBoardStatus::Inbox,
        ),
        TaskBoardStatus::Done
    );
    assert_eq!(
        reconciled_external_status(TaskBoardStatus::Done, None, TaskBoardStatus::Inbox),
        TaskBoardStatus::Done
    );
}

#[test]
fn external_status_reconciliation_canonicalizes_legacy_shared_truth() {
    for (current, last_synced, expected) in [
        (
            TaskBoardStatus::Todo,
            TaskBoardStatus::New,
            TaskBoardStatus::Done,
        ),
        (
            TaskBoardStatus::AgenticReview,
            TaskBoardStatus::PlanReview,
            TaskBoardStatus::AgenticReview,
        ),
        (
            TaskBoardStatus::HumanRequired,
            TaskBoardStatus::NeedsYou,
            TaskBoardStatus::HumanRequired,
        ),
        (
            TaskBoardStatus::Failed,
            TaskBoardStatus::Blocked,
            TaskBoardStatus::Failed,
        ),
    ] {
        assert_eq!(
            reconciled_external_status(current, Some(last_synced), TaskBoardStatus::Done),
            expected
        );
    }
}
